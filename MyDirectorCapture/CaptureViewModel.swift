import Foundation
import SwiftUI
import AVFoundation
import LiveKit
import Combine
import UIKit

@MainActor
final class CaptureViewModel: ObservableObject {

    // MARK: - Published UI State

    @Published var status = "Ready"
    @Published var error: String?
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsed = "00:00"

    // Camera is running (preview visible) - true before recording starts.
    @Published var isCameraOn = false
    @Published var isStarting = false

    // Live health of the file being written (A/V offset, drops).
    @Published var fileStats = ""

    // LiveKit call state, shown separately from the recording status.
    @Published var callStatus = "Call: not connected"

    @Published var savedFiles: [URL] = []

    // Duration of each saved file ("0:10"), so the file length can be
    // checked against the on-screen timer without opening the file.
    @Published var fileDurations: [URL: String] = [:]

    @Published var recoveryMessage =
        "No unfinished recording found."

    // Files recovered at launch after the app was killed mid-recording.
    private var recoveredFiles: [URL] = []

    @Published var showInterruption = false
    @Published var interruptionMessage = ""

    // MARK: - Capture

    private let capture = CaptureEngine()

    var captureSession: AVCaptureSession {
        capture.captureSession
    }

    // MARK: - LiveKit

    private var room: Room?

    // Strong reference; LiveKit keeps delegates weak.
    private var roomObserver: LiveKitRoomObserver?

    private var roomURL = ""
    private var roomToken = ""

    private let liveKitRoomName =
        "mydirector-poc"

    // MARK: - Timer

    private var timer: Timer?
    private var startedAt: Date?
    private var accumulated: TimeInterval = 0

    private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    init() {

        capture.onError = { [weak self] message in

            Task { @MainActor in

                self?.error = message
                self?.status = "Recording error"
            }
        }

        capture.onWarning = { [weak self] message in

            Task { @MainActor in
                // Shown, but the recording state is not changed.
                self?.error = message
            }
        }

        capture.onStats = { [weak self] text in

            Task { @MainActor in
                self?.fileStats = text
            }
        }

        // Scenario D: an app kill leaves a `.recording` marker. Recover the
        // (fragmented, still playable) file before anything else records.
        recoveredFiles = CaptureEngine.recoverInterruptedSegments()

        refreshFiles()

        installObservers()
    }

    deinit {

        observers.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Start

    func start(
        url: String,
        token: String
    ) async {

        guard !isRecording, !isStarting else {
            return
        }

        error = nil

        roomURL = url
        roomToken = token
        kickedByDuplicateIdentity = false

        do {

            isStarting = true

            // 1. Camera first: the preview appears right away while the
            //    call connects. Nothing is written to the file yet.
            status = "Starting camera…"

            try await capture.start()
            try await capture.waitForFirstVideoFrame()

            isCameraOn = true

            // 2. LiveKit call.
            status = "Connecting to LiveKit…"

            try await joinCall(url: url, token: token)

            // Starting the call's video encoder stalls the camera for a few
            // seconds. Let that pass before the file opens, so the file has
            // no frozen/missing stretch at the start.
            status = "Waiting for the call video to settle…"

            let stable = await capture.waitForStableCamera()
            if !stable {
                self.error = "The camera did not run smoothly within 10 s after joining the call. Recording anyway; the start of the file may have gaps."
            }

            // 3. Everything is up: open the file and start the timer at
            //    the same moment, so the file length matches the timer.
            status = "Preparing the recording file…"
            try await capture.startRecording()

            isStarting = false
            isRecording = true
            isPaused = false

            accumulated = 0
            startedAt = Date()

            startClock()

            status =
                "Recording + LiveKit connected"

        } catch let startError {

            self.error = startError.localizedDescription
            status = "Start failed"

            await capture.stop()

            isStarting = false
            isCameraOn = false

            if let room {
                await room.disconnect()
                self.room = nil
            }

            roomObserver = nil
            callStatus = "Call: not connected"
        }
    }

    // MARK: - LiveKit call (join / rejoin)

    private var callGeneration = 0
    private var isRejoining = false

    /// Set when LiveKit removed us because another participant joined with
    /// the SAME identity (same token used on two devices). Rejoining would
    /// just kick the other device out, so we never auto-rejoin after this.
    private var kickedByDuplicateIdentity = false

    /// Connects to the room, starts the microphone and publishes the camera.
    /// Used by Start and to rejoin the SAME room after a drop.
    private func joinCall(
        url: String,
        token: String
    ) async throws {

        callGeneration += 1
        let generation = callGeneration

        let newRoom = Room()

        // Events from an older (replaced) room are ignored.
        let observer = LiveKitRoomObserver(
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    guard let self, self.callGeneration == generation else { return }
                    self.callStateChanged(state)
                }
            },
            onDisconnect: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.callGeneration == generation else { return }
                    self.callDisconnected(message)
                }
            }
        )

        newRoom.delegates.add(delegate: observer)
        roomObserver = observer

        try await newRoom.connect(
            url: url,
            token: token
        )

        room = newRoom

        // MARK: LiveKit Video Track

        let track =
            await LocalVideoTrack.createBufferTrack(
                name: "mydirector-camera",
                source: .camera,
                options:
                    BufferCaptureOptions(
                        dimensions:
                            Dimensions(
                                width: Int32(CaptureEngine.callWidth),
                                height: Int32(CaptureEngine.callHeight)
                            ),
                        fps: 30
                    ),
                reportStatistics: true
            )

        guard let bufferCapturer =
            track.capturer as? BufferCapturer
        else {
            throw CaptureError
                .liveKitBufferCapturerUnavailable
        }

        // SAME camera frames (a 720p copy) go to LiveKit. The buffers are
        // already upright portrait, so no rotation is applied.
        capture.onVideoFrame = { pixelBuffer, timestamp in
            bufferCapturer.capture(
                pixelBuffer,
                timeStampNs: timestamp,
                rotation: ._0
            )
        }

        // LiveKit is the only owner of the microphone (voice processing +
        // echo cancellation on). The local file records this same audio.
        try await enableMicrophone(in: newRoom)

        try await newRoom.localParticipant.publish(
            videoTrack: track
        )
    }

    private func enableMicrophone(in room: Room) async throws {
        try await room.localParticipant.setMicrophone(
            enabled: true,
            captureOptions: AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true,
                highpassFilter: true
            )
        )
    }

    /// Makes sure we are in the call before resuming. LiveKit reconnects
    /// by itself after a short drop: wait for that (up to 15 s). If the
    /// room is gone, join the SAME room again.
    private func ensureCallConnected() async throws {

        if let room, room.connectionState == .connected {
            return
        }

        guard !kickedByDuplicateIdentity else {
            throw CaptureError.duplicateIdentity
        }

        status = "Rejoining the call…"

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let room else { break }
            if room.connectionState == .connected {
                return
            }
            if room.connectionState == .disconnected { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        try await rejoinCall()
    }

    /// Leaves the old room object and joins the same room again.
    private func rejoinCall() async throws {

        status = "Rejoining the call…"

        let old = room
        room = nil
        roomObserver = nil
        callGeneration += 1          // silence events from the old room
        capture.onVideoFrame = nil

        if let old {
            await old.disconnect()
        }

        try await joinCall(url: roomURL, token: roomToken)
    }

    /// After a phone call iOS may not hand the microphone back to LiveKit.
    /// Turn it on, check that audio really flows, and restart it once if not.
    private func restartMicrophoneAfterInterruption(in room: Room) async {

        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            try await enableMicrophone(in: room)
        } catch let micError {
            self.error = "Could not turn the microphone back on: \(micError.localizedDescription)"
            return
        }

        if await capture.waitForMicrophoneAudio(timeout: 3) {
            return
        }

        try? await room.localParticipant.setMicrophone(enabled: false)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? await enableMicrophone(in: room)

        if !(await capture.waitForMicrophoneAudio(timeout: 3)) {
            self.error = "The microphone did not come back after the interruption. Recording continues without audio — stop and start again."
        }
    }

    /// Asks iOS for time to finish saving the file, even if the app is
    /// about to be suspended (home screen / lock / incoming call).
    private func withBackgroundTime(
        _ name: String,
        _ work: () async -> Void
    ) async {

        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }

        await work()

        if box.id != .invalid {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
    }

    // MARK: - LiveKit Call State

    private func callStateChanged(_ state: ConnectionState) {

        switch state {

        case .connecting:
            callStatus = "Call: connecting…"

        case .connected:
            callStatus = "Call: connected"

        case .reconnecting:
            callStatus = "Call: reconnecting… (local recording continues)"

        case .disconnecting, .disconnected:
            callStatus = "Call: disconnected"

        @unknown default:
            callStatus = "Call: unknown state"
        }
    }

    // nil = normal disconnect from Stop.
    private func callDisconnected(_ message: String?) {

        callStatus = "Call: disconnected"

        guard let message else {
            return
        }

        if message.lowercased().contains("duplicate") {
            kickedByDuplicateIdentity = true
            error = CaptureError.duplicateIdentity.localizedDescription
            return
        }

        error =
            "LiveKit call disconnected: \(message). Local recording continues."

        // Recording: rejoin the same room right away. Paused: Resume rejoins.
        guard isRecording, !isPaused, !isRejoining else { return }

        isRejoining = true
        Task { @MainActor in
            defer { self.isRejoining = false }
            do {
                try await self.rejoinCall()
                self.error = nil
                self.status = "Recording + LiveKit rejoined"
            } catch let rejoinError {
                self.error = "LiveKit call lost and could not rejoin: \(rejoinError.localizedDescription). Local recording continues."
            }
        }
    }

    // MARK: - Pause

    func pause(
        reason: String
    ) async {

        guard
            isRecording,
            !isPaused
        else {
            return
        }

        // Set immediately: .inactive and .background usually arrive
        // back-to-back and must not pause (and alert) twice.
        isPaused = true

        accumulated +=
            Date().timeIntervalSince(
                startedAt ?? Date()
            )

        startedAt = nil

        timer?.invalidate()
        timer = nil

        await withBackgroundTime("pause-recording") {
            await capture.pause()
        }

        if let room {

            do {
                try await room.localParticipant
                    .setMicrophone(
                        enabled: false
                    )
            } catch let micError {
                self.error =
                    "Could not mute the LiveKit microphone: \(micError.localizedDescription)"
            }
        }

        isPaused = true

        status =
            "Paused — \(reason)"

        interruptionMessage =
            """
            Capture paused because \(reason).

            Completed recording segments are saved.
            Resume when the device is available.
            """

        showInterruption = true

        refreshFiles()
    }

    // MARK: - Resume

    func resume() async {

        guard isPaused else {
            return
        }

        do {

            // 1. Back in the call (waits for LiveKit's reconnect, or
            //    rejoins the same room).
            try await ensureCallConnected()

            guard let room else {
                throw CaptureError.liveKitDisconnected
            }

            // 2. Mic first, and check it really delivers audio again (a
            //    phone call may keep it), so the new file has audio from
            //    its first frame.
            status = "Restarting the microphone…"
            await restartMicrophoneAfterInterruption(in: room)

            // 3. Camera + next file.
            status = "Resuming the recording…"
            try await capture.resume()

            isPaused = false
            isRecording = true

            startedAt = Date()

            startClock()

            status =
                "Recording resumed"

        } catch let resumeError {

            self.error = resumeError.localizedDescription
            status = "Resume failed"
        }
    }

    // MARK: - Stop

    func stop() async {

        timer?.invalidate()
        timer = nil

        await withBackgroundTime("stop-recording") {
            await capture.stop()
        }

        if let room {

            await room.disconnect()

            self.room = nil
        }

        roomObserver = nil
        callStatus = "Call: not connected"

        isRecording = false
        isPaused = false
        isCameraOn = false
        startedAt = nil
        fileStats = ""

        status =
            "Stopped — files saved"

        refreshFiles()
    }

    // MARK: - App Lifecycle

    func appPhaseChanged(_ phase: ScenePhase) {

        guard isRecording else {
            return
        }

        switch phase {

        case .background:
            Task {
                await pause(
                    reason: "the app went to background"
                )
            }

        case .inactive:
            Task {
                await pause(
                    reason: "the app became inactive"
                )
            }

        case .active:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Timer

    private func startClock() {

        timer?.invalidate()

        timer =
            Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] _ in

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    let seconds =
                        Int(
                            self.accumulated +
                            Date().timeIntervalSince(
                                self.startedAt ?? Date()
                            )
                        )

                    self.elapsed =
                        String(
                            format: "%02d:%02d",
                            seconds / 60,
                            seconds % 60
                        )
                }
            }
    }

    // MARK: - Observers

    private func installObservers() {

        let center =
            NotificationCenter.default

        // Phone call / audio interruption.
        observers.append(
            center.addObserver(
                forName:
                    AVAudioSession
                        .interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in

                guard let self else {
                    return
                }

                let raw =
                    note.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? UInt

                guard
                    raw ==
                        AVAudioSession
                            .InterruptionType
                            .began
                            .rawValue
                else {
                    return
                }

                Task { @MainActor in

                    await self.pause(
                        reason:
                            "an audio interruption / phone call began"
                    )
                }
            }
        )

        // Best effort only.
        //
        // iOS may terminate the process without
        // delivering willTerminate.
        observers.append(
            center.addObserver(
                forName:
                    UIApplication
                        .willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    await self?.capture
                        .finalizeCurrentSegment()
                }
            }
        )

        // Camera runtime error.
        observers.append(
            center.addObserver(
                forName:
                    AVCaptureSession
                        .runtimeErrorNotification,
                object: capture.captureSession,
                queue: .main
            ) { [weak self] note in

                let captureError =
                    note.userInfo?[AVCaptureSessionErrorKey] as? Error

                Task { @MainActor in

                    guard let self else {
                        return
                    }

                    self.error =
                        "Camera error: \(captureError?.localizedDescription ?? "unknown error"). Completed segments are saved."

                    await self.pause(
                        reason: "the camera stopped with an error"
                    )
                }
            }
        )

        // Camera interrupted by the system.
        observers.append(
            center.addObserver(
                forName:
                    AVCaptureSession
                        .wasInterruptedNotification,
                object: capture.captureSession,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in

                    await self?.pause(
                        reason: "the camera was interrupted by the system"
                    )
                }
            }
        )

        // Refresh file list whenever a segment finishes.
        observers.append(
            center.addObserver(
                forName:
                    .captureFilesChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in

                Task { @MainActor in
                    self?.refreshFiles()
                }
            }
        )
    }

    // MARK: - Files

    func refreshFiles() {

        savedFiles =
            CaptureEngine.savedSegments()

        loadDurations()

        let recovered = recoveredFiles.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }

        if !recovered.isEmpty {

            let names = recovered
                .map(\.lastPathComponent)
                .joined(separator: ", ")

            recoveryMessage =
                """
                An unfinished recording was found: the app was closed while recording.

                Recovered: \(names). It plays up to about 2 seconds before the app was closed.
                """

        } else if savedFiles.isEmpty {

            recoveryMessage =
                "No completed segments found."

        } else {

            recoveryMessage =
                """
                Found \(savedFiles.count) finalized segment(s).

                Completed segments remain playable after an interruption or force-quit.
                """
        }
    }

    private func loadDurations() {

        let files = savedFiles

        Task { [weak self] in

            var result: [URL: String] = [:]

            for url in files {

                let asset = AVURLAsset(url: url)

                if let duration = try? await asset.load(.duration),
                   duration.isNumeric {

                    let seconds = Int(CMTimeGetSeconds(duration).rounded())
                    result[url] = String(format: "%d:%02d", seconds / 60, seconds % 60)

                } else {

                    result[url] = "unreadable"
                }
            }

            self?.fileDurations = result
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {

    case liveKitBufferCapturerUnavailable
    case liveKitDisconnected
    case duplicateIdentity

    var errorDescription: String? {

        switch self {

        case .liveKitBufferCapturerUnavailable:
            return "LiveKit BufferCapturer could not be created."

        case .duplicateIdentity:
            return "Removed from the call: another device joined the room with the SAME identity (the same token is used on the phone and in the browser). Give the browser a token with a different identity. Local recording continues."

        case .liveKitDisconnected:
            return "Could not get back into the LiveKit call. Check the network, then tap Resume again."
        }
    }
}

// MARK: - LiveKit Room Observer

// RoomDelegate is @objc, so this needs to be an NSObject.
final class LiveKitRoomObserver: NSObject, RoomDelegate, @unchecked Sendable {

    private let onStateChange: @Sendable (ConnectionState) -> Void
    private let onDisconnect: @Sendable (String?) -> Void

    init(
        onStateChange: @escaping @Sendable (ConnectionState) -> Void,
        onDisconnect: @escaping @Sendable (String?) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onDisconnect = onDisconnect
    }

    func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        onStateChange(connectionState)
    }

    func room(
        _ room: Room,
        didDisconnectWithError error: LiveKitError?
    ) {
        onDisconnect(error?.localizedDescription)
    }
}

/// Holds a background task id for the expiration handler.
final class BackgroundTaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}
