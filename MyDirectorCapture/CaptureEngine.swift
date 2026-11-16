import Foundation
import AVFoundation
import UIKit
import CoreVideo
import VideoToolbox
import LiveKit

/// Owns the camera and the local recording file.
///
/// Design (one owner per device):
///   * Camera     -> ONE AVCaptureSession (video only). Every frame goes to
///                   LiveKit (BufferCapturer) AND to the AVAssetWriter.
///   * Microphone -> owned ONLY by LiveKit/WebRTC (voice processing with echo
///                   cancellation). The file gets the SAME processed microphone
///                   audio through `AudioManager.shared.add(localAudioRenderer:)`.
///
/// The previous version also added the microphone to the AVCaptureSession.
/// Two clients then fought over the mic / audio session: the capture
/// session's audio clock was reset when LiveKit reconfigured the audio
/// session, which stretched the file timeline (10 s recording -> ~40 s file
/// with black/silent gaps), and the file got the raw, non-echo-cancelled mic
/// (mostly the interviewer from the speaker instead of the user's voice).
///
/// All timestamps (video and audio) are on the host clock so they line up.
///
/// Files are QuickTime movies written with `movieFragmentInterval`, so if
/// the app is killed the file is still playable up to the last fragment
/// (~2 s before the crash).
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called for every camera frame: (pixelBuffer, host-clock timestamp in ns).
    var onVideoFrame: ((CVPixelBuffer, Int64) -> Void)?
    /// Called (on main) for any failure or problem the user must see.
    var onError: ((String) -> Void)?
    /// Called (on main) about once a second while writing, with live file
    /// health: audio/video offset and drop counters.
    var onStats: ((String) -> Void)?
    /// Called (on main) for problems that do not stop the recording
    /// (e.g. the call's video falling behind). Shown on screen.
    var onWarning: ((String) -> Void)?

    // MARK: - Configuration

    nonisolated static let fileExtension = "mov"
    nonisolated private static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    nonisolated private static let videoBitRate = 10_000_000
    nonisolated private static let audioSampleRate: Double = 48_000

    // MARK: - Capture

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.mydirector.capture.session")
    private let writerQueue = DispatchQueue(label: "com.mydirector.capture.writer")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let hostClock = CMClockGetHostTimeClock()

    // The call gets its OWN 720p copy of each frame. Camera buffers are
    // never handed to LiveKit/WebRTC: if the call's encoder holds frames
    // (startup, weak network, heat) it can no longer starve the camera's
    // small buffer pool, which froze the file for ~8 s after Start.
    nonisolated static let callWidth = 720
    nonisolated static let callHeight = 1280
    private var callTransfer: VTPixelTransferSession?
    private var callPool: CVPixelBufferPool?
    /// LiveKit gets frames on its OWN queue: if LiveKit/WebRTC blocks, the
    /// camera delegate queue (and so the file) is never held up.
    private let callQueue = DispatchQueue(label: "com.mydirector.capture.call")
    private let callInFlightLock = NSLock()
    private var callInFlight = 0
    private var callSkippedOnQueue = 0
    private var lastCallSkippedTotal = 0
    private var reportedCallBehind = false
    private var reportedMixMismatch = false

    // Microphone buffers received (any time, also while paused).
    private let micCountLock = NSLock()
    private var micBuffersTotal = 0
    private var sessionConfigured = false

    var captureSession: AVCaptureSession { session }

    // MARK: - Microphone tap (LiveKit processed mic -> file)

    private lazy var micTap = MicrophoneTap { [weak self] buffer in
        self?.handleMicrophoneBuffer(buffer)
    }
    private var micTapInstalled = false
    /// The interviewer (all remote participants, as played out) mixed into
    /// the file. The microphone is echo-cancelled, so without this the
    /// interviewer would not be in the recording at all.
    private let remoteMixer = RemoteAudioMixer()
    private let audioTimeline = AudioTimeline()

    // MARK: - Writer state (writerQueue only)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var currentMarkerURL: URL?
    private var segmentStart: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var isWriting = false
    private var isPaused = false
    /// The camera can run (preview + call) before the file is opened.
    /// Only `startRecording()` lets frames into the file, so the file
    /// starts exactly when the user sees "Recording" and the timer starts.
    private var isRecordingArmed = false
    /// Audio waiting for the writer's interleaving (never dropped silently).
    private var pendingAudio: [CMSampleBuffer] = []
    private var lastAudioEnd: CMTime = .invalid
    private var framesSinceStats = 0

    // Diagnostics (writerQueue), shown on screen and in the Xcode console.
    private var cameraDropsLate = 0
    private var cameraDropsOutOfBuffers = 0
    private var cameraDropsOther = 0
    private var callFramesSkipped = 0
    private var lastAudioReceivedPTS: CMTime = .invalid

    // Camera stability (lock-protected, read from the main actor).
    private let stabilityLock = NSLock()
    private var framesSinceCameraDrop = 0
    private var segmentNumber = 0
    private var syncClock: CMClock?
    private var droppedVideoFrames = 0
    private var droppedAudioBuffers = 0
    private var reportedWriterFailure = false
    private var reportedMissingAudio = false
    private var reportedDrops = false

    private var videoFrameCount = 0
    private let videoFrameCountLock = NSLock()

    // MARK: - Lifecycle

    func start() async throws {
        try await requestPermissions()
        // Create the 720p scaler + pool now, off the camera queue (its first
        // use was measured at 2.3 s on the device).
        callQueue.async {
            self.prepareCallScaler()
        }
        installMicTap()
        audioTimeline.reset()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.sessionConfigured {
                        try self.configureSession()
                        self.sessionConfigured = true
                    }

                    self.videoFrameCountLock.lock()
                    self.videoFrameCount = 0
                    self.videoFrameCountLock.unlock()

                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    let clock = self.session.synchronizationClock
                    self.writerQueue.sync {
                        self.syncClock = clock
                        self.isPaused = false
                        self.isRecordingArmed = false
                        self.reportedWriterFailure = false
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Opens the local file on the next camera frame. Call when the call is
    /// fully set up and the UI switches to "Recording".
    func startRecording() async throws {
        try await prepareNextSegment()
        audioTimeline.reset()
        remoteMixer.reset()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                self.isRecordingArmed = true
                self.isPaused = false
                continuation.resume()
            }
        }
    }

    func pause() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.session.stopRunning()
                self.writerQueue.async {
                    self.isPaused = true
                    self.finishSegment { continuation.resume() }
                }
            }
        }
    }

    func resume() async throws {
        // Prepare the next file OFF the camera queue before frames flow.
        try await prepareNextSegment()
        audioTimeline.reset()
        remoteMixer.reset()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let clock = self.session.synchronizationClock
                self.writerQueue.async {
                    self.syncClock = clock
                    self.isPaused = false
                    continuation.resume()
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.session.stopRunning()
                self.writerQueue.async {
                    self.isPaused = false
                    self.isRecordingArmed = false
                    if let unused = self.prepared {
                        Self.discard(unused)
                        self.prepared = nil
                    }
                    self.finishSegment { continuation.resume() }
                }
            }
        }
        removeMicTap()
    }

    func finalizeCurrentSegment() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                self.finishSegment { continuation.resume() }
            }
        }
    }

    /// Waits until the camera has delivered `stableFrames` frames in a row
    /// without a drop. Starting the call's video encoder makes the camera
    /// stall for a few seconds; this lets that happen BEFORE the file opens.
    /// Returns false on timeout.
    func waitForStableCamera(stableFrames: Int = 60, timeout: TimeInterval = 10) async -> Bool {
        stabilityLock.withLock { framesSinceCameraDrop = 0 }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stable = stabilityLock.withLock { framesSinceCameraDrop >= stableFrames }
            if stable { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// True as soon as new microphone audio arrives from LiveKit within
    /// `timeout`. Used after a phone call: iOS may not hand the mic back.
    func waitForMicrophoneAudio(timeout: TimeInterval = 3) async -> Bool {
        let before = micCountLock.withLock { micBuffersTotal }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = micCountLock.withLock { micBuffersTotal }
            if now - before >= 5 { return true }   // ~50 ms of audio
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func waitForFirstVideoFrame(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let hasFrame = videoFrameCountLock.withLock { videoFrameCount > 0 }
            if hasFrame { return }
            if Date() >= deadline { throw CaptureEngineError.firstVideoFrameTimeout }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Session setup (sessionQueue)

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // The microphone belongs to LiveKit. The capture session must not
        // touch the app's AVAudioSession.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .hd1920x1080

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CaptureEngineError.noCamera
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else { throw CaptureEngineError.cannotAddInput }
        session.addInput(cameraInput)

        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
        }) else {
            throw CaptureEngineError.unsupportedFormat("The front camera cannot run 1080p at 30 fps.")
        }
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        } catch {
            throw CaptureEngineError.unsupportedFormat("Could not lock the camera to 30 fps: \(error.localizedDescription)")
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureEngineError.cannotAddOutput }
        session.addOutput(videoOutput)

        guard let connection = videoOutput.connection(with: .video) else {
            throw CaptureEngineError.cannotAddOutput
        }
        // Rotate the pixel buffers to portrait (1080x1920). Because the
        // buffers are already upright, NO extra transform is written to the
        // file and LiveKit gets rotation ._0.
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }

    // MARK: - Video (writerQueue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            reportError("Camera frame did not contain image data.")
            return
        }

        // Express the frame time on the host clock (same clock as the mic tap).
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var pts = rawPTS
        var frame = sampleBuffer
        if let syncClock, !CFEqual(syncClock, hostClock) {
            pts = CMSyncConvertTime(rawPTS, from: syncClock, to: hostClock)
            if let retimed = Self.retime(sampleBuffer, to: pts) { frame = retimed }
        }

        videoFrameCountLock.lock()
        videoFrameCount += 1
        videoFrameCountLock.unlock()

        frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        stabilityLock.lock()
        framesSinceCameraDrop += 1
        stabilityLock.unlock()

        // Same frame -> LiveKit call. Scaling to 720p and LiveKit's capture()
        // both run on the call queue (max 2 camera buffers in flight), so a
        // slow call can never block the camera queue / the file.
        handOffToCall(pixelBuffer, timestampNs: Int64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000))

        // Same frame -> local file (only once recording is armed).
        guard isRecordingArmed, !isPaused else { return }
        if writer == nil {
            beginSegment(at: pts, pixelBuffer: pixelBuffer)
        }
        appendVideo(frame)
        drainAudio()
        checkAudioHealth(videoPTS: pts)
        publishStats(videoPTS: pts)
    }

    private func publishStats(videoPTS: CMTime) {
        guard isWriting else { return }
        framesSinceStats += 1
        guard framesSinceStats >= 30 else { return }
        framesSinceStats = 0
        let offsetMs: Double? = lastAudioEnd.isValid
            ? CMTimeGetSeconds(lastAudioEnd - videoPTS) * 1000
            : nil
        let offset = offsetMs.map { String(format: "%+.0f ms", $0) } ?? "no audio yet"

        // Shown only when something is wrong with the file being written:
        // audio/video out of sync, audio backing up, or dropped media.
        // When everything is healthy the line stays hidden (empty text).
        let outOfSync = offsetMs.map { abs($0) > 100 } ?? false
        let backingUp = pendingAudio.count > 50              // > 0.5 s waiting
        let dropped = droppedAudioBuffers > 0 || droppedVideoFrames > 0
        let text = (outOfSync || backingUp || dropped)
            ? "File A/V: \(offset) · audio queued \(pendingAudio.count) · dropped A \(droppedAudioBuffers) / V \(droppedVideoFrames)"
            : ""
        let rm = remoteMixer.counters()

        // No silent failures for the call side either.
        let callSkippedTotal = callFramesSkipped + callSkippedOnQueue
        if callSkippedTotal - lastCallSkippedTotal > 15, !reportedCallBehind {
            reportedCallBehind = true
            reportWarning("The call's video is falling behind (\(callSkippedTotal - lastCallSkippedTotal) frames skipped in the last second). The other side may see a frozen or choppy picture. The local file is not affected.")
        }
        lastCallSkippedTotal = callSkippedTotal
        if rm.mismatch > 0, !reportedMixMismatch {
            reportedMixMismatch = true
            reportWarning("The interviewer's audio could not be mixed into the file (format \(rm.format) does not match the microphone). The file has only the user's voice.")
        }
        DispatchQueue.main.async { [weak self] in self?.onStats?(text) }
    }

    /// Camera-side drops. "OutOfBuffers" means someone held on to camera
    /// buffers; "FrameWasLate" means this queue was too slow.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer,
                                     key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String
        let late = kCMSampleBufferDroppedFrameReason_FrameWasLate as String
        let outOfBuffers = kCMSampleBufferDroppedFrameReason_OutOfBuffers as String
        if reason == late {
            cameraDropsLate += 1
        } else if reason == outOfBuffers {
            cameraDropsOutOfBuffers += 1
        } else {
            cameraDropsOther += 1
        }
        stabilityLock.lock()
        framesSinceCameraDrop = 0
        stabilityLock.unlock()
        let total = cameraDropsLate + cameraDropsOutOfBuffers + cameraDropsOther
        if isWriting, total == 15 {
            reportError("The camera is dropping frames (late: \(cameraDropsLate), out of buffers: \(cameraDropsOutOfBuffers)). The recording will have gaps.")
        }
    }

    private func callInFlightCount() -> Int {
        callInFlightLock.lock(); defer { callInFlightLock.unlock() }
        return callInFlight
    }

    private func handOffToCall(_ buffer: CVPixelBuffer, timestampNs: Int64) {
        callInFlightLock.lock()
        guard callInFlight < 2 else {
            callInFlightLock.unlock()
            callFramesSkipped += 1
            return
        }
        callInFlight += 1
        callInFlightLock.unlock()

        callQueue.async {
            guard let copy = self.makeCallCopy(of: buffer) else {
                self.callInFlightLock.lock()
                self.callInFlight -= 1
                self.callSkippedOnQueue += 1
                self.callInFlightLock.unlock()
                return
            }
            self.onVideoFrame?(copy, timestampNs)
            self.callInFlightLock.lock()
            self.callInFlight -= 1
            self.callInFlightLock.unlock()
        }
    }

    /// Scales the camera frame to 720p into our own buffer pool for the
    /// call. Returns nil (call skips this frame, file is unaffected) if the
    /// call still holds too many of our buffers.
    private func makeCallCopy(of source: CVPixelBuffer) -> CVPixelBuffer? {
        prepareCallScaler()
        guard let callTransfer, let callPool else { return nil }

        var out: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, callPool, aux, &out) == kCVReturnSuccess,
              let out else { return nil }
        guard VTPixelTransferSessionTransferImage(callTransfer, from: source, to: out) == noErr else { return nil }
        return out
    }

    /// callQueue only.
    private func prepareCallScaler() {
        if callTransfer == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            if let session {
                VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                     value: kVTScalingMode_Normal)
            }
            callTransfer = session
        }
        if callPool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: Self.callWidth,
                kCVPixelBufferHeightKey as String: Self.callHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &callPool)
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard isWriting, let writer, let videoInput else { return }
        guard writer.status == .writing else {
            reportWriterFailure(writer, prefix: "Recording stopped unexpectedly")
            return
        }
        guard videoInput.isReadyForMoreMediaData else {
            droppedVideoFrames += 1
            reportDropsIfNeeded()
            return
        }
        if !videoInput.append(sample) {
            reportWriterFailure(writer, prefix: "A video frame could not be written")
        }
    }

    // MARK: - Audio (mic tap -> writerQueue)

    private func installMicTap() {
        guard !micTapInstalled else { return }
        AudioManager.shared.add(localAudioRenderer: micTap)
        AudioManager.shared.add(remoteAudioRenderer: remoteMixer)
        micTapInstalled = true
    }

    private func removeMicTap() {
        guard micTapInstalled else { return }
        AudioManager.shared.remove(localAudioRenderer: micTap)
        AudioManager.shared.remove(remoteAudioRenderer: remoteMixer)
        micTapInstalled = false
    }

    /// Runs on the WebRTC audio thread, ~every 10 ms, with the
    /// echo-cancelled microphone audio that is also sent to the call.
    private func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        micCountLock.lock()
        micBuffersTotal += 1
        micCountLock.unlock()
        let arrival = CMClockGetTime(hostClock)
        // Mix the interviewer into this mic chunk (the buffer is our own
        // copy; the call's audio is not changed).
        remoteMixer.mix(into: buffer)
        // nil = our sample-counted timeline ran ahead of real time; skip this
        // 10 ms chunk so audio cannot drift ahead of video.
        guard let pts = audioTimeline.timestamp(frames: buffer.frameLength,
                                                sampleRate: buffer.format.sampleRate,
                                                arrival: arrival) else { return }
        guard let sample = Self.makeAudioSampleBuffer(buffer, pts: pts) else {
            reportError("Microphone audio could not be converted for the recording.")
            return
        }
        writerQueue.async { self.appendAudio(sample, pts: pts) }
    }

    private func appendAudio(_ sample: CMSampleBuffer, pts: CMTime) {
        lastAudioReceivedPTS = pts
        guard isWriting, !isPaused, let writer, audioInput != nil else { return }
        guard writer.status == .writing else {
            reportWriterFailure(writer, prefix: "Recording stopped unexpectedly")
            return
        }
        // Audio captured before the first video frame of this file.
        guard segmentStart.isValid, pts >= segmentStart else { return }
        pendingAudio.append(sample)
        drainAudio()
    }

    /// AVAssetWriter interleaves audio and video. When audio runs a little
    /// ahead it reports "not ready" until video catches up. The old code
    /// DROPPED audio at that point, and once that happened it kept happening
    /// - the "voice disappears after a while" bug. Audio now waits in a
    /// queue and is written as soon as the writer accepts it.
    private func drainAudio() {
        guard isWriting, let writer, let audioInput, writer.status == .writing else { return }
        while let next = pendingAudio.first, audioInput.isReadyForMoreMediaData {
            pendingAudio.removeFirst()
            if audioInput.append(next) {
                let pts = CMSampleBufferGetPresentationTimeStamp(next)
                lastAudioPTS = pts
                lastAudioEnd = pts + CMSampleBufferGetDuration(next)
            } else {
                pendingAudio.removeAll()
                reportWriterFailure(writer, prefix: "Microphone audio could not be written")
                return
            }
        }
        // Safety cap (~3 s of 10 ms chunks). Hitting it means the writer is
        // truly stuck: tell the user instead of growing memory forever.
        let cap = 300
        if pendingAudio.count > cap {
            droppedAudioBuffers += pendingAudio.count - cap
            pendingAudio.removeFirst(pendingAudio.count - cap)
            reportDropsIfNeeded()
        }
    }

    /// No silent failures: if no microphone audio reaches the file for 2 s
    /// while video is being recorded, tell the user.
    private func checkAudioHealth(videoPTS: CMTime) {
        guard isWriting, !reportedMissingAudio, segmentStart.isValid else { return }
        // Judge by audio RECEIVED from the mic, not audio written: written
        // audio can legitimately wait in the queue while video catches up.
        let reference = (lastAudioReceivedPTS.isValid && lastAudioReceivedPTS > segmentStart)
            ? lastAudioReceivedPTS : segmentStart
        if CMTimeGetSeconds(videoPTS - reference) > 2.0 {
            reportedMissingAudio = true
            reportError("No microphone audio is reaching the recording file. Check that the LiveKit microphone is enabled and not muted.")
        }
    }

    private func reportDropsIfNeeded() {
        guard !reportedDrops else { return }
        reportedDrops = true
        reportError("The recorder could not keep up and dropped media (video frames: \(droppedVideoFrames), audio buffers: \(droppedAudioBuffers)). The device may be too hot or busy.")
    }

    // MARK: - Segments (writerQueue)

    /// A writer that is already created and started (`startWriting`),
    /// waiting for its first frame. Preparing it OFF the camera queue is the
    /// fix for the frozen start: `startWriting()` was measured at 5.2 s on
    /// the device, and the camera dropped every frame while it blocked.
    nonisolated private struct PreparedSegment {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        let url: URL
        let markerURL: URL
    }
    private var prepared: PreparedSegment?           // writerQueue
    private let prepQueue = DispatchQueue(label: "com.mydirector.capture.prepare")
    private var frameWidth = 0                         // writerQueue
    private var frameHeight = 0                        // writerQueue

    /// Creates and starts the next file writer in the background.
    /// Call before arming / resuming; nothing is written until a frame comes.
    func prepareNextSegment() async throws {
        let (width, height, number): (Int, Int, Int) = writerQueue.sync {
            self.segmentNumber = max(self.segmentNumber, Self.highestSegmentNumber()) + 1
            return (self.frameWidth, self.frameHeight, self.segmentNumber)
        }
        guard min(width, height) >= 1080 else {
            throw CaptureEngineError.unsupportedFormat("Camera delivered \(width)x\(height); at least 1080p is required.")
        }
        let segment: PreparedSegment = try await withCheckedThrowingContinuation { continuation in
            prepQueue.async {
                do {
                    continuation.resume(returning: try Self.makeSegment(number: number, width: width, height: height))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        writerQueue.sync {
            if let old = self.prepared { Self.discard(old) }
            self.prepared = segment
        }
    }

    nonisolated private static func makeSegment(number: Int, width: Int, height: Int) throws -> PreparedSegment {
        let base = String(format: "segment-%04d", number)
        let url = directory().appendingPathComponent(base).appendingPathExtension(fileExtension)
        let markerURL = directory().appendingPathComponent(base).appendingPathExtension("recording")
        try? FileManager.default.removeItem(at: url)

        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Crash safety: the movie header is rewritten every 2 s, so a
        // killed app leaves a file playable up to the last fragment.
        w.movieFragmentInterval = fragmentInterval

        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        v.expectsMediaDataInRealTime = true

        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ])
        a.expectsMediaDataInRealTime = true

        guard w.canAdd(v), w.canAdd(a) else { throw CaptureEngineError.cannotAddWriterInput }
        w.add(v)
        w.add(a)

        guard w.startWriting() else {
            throw CaptureEngineError.writerStartFailed(w.error?.localizedDescription ?? "Unknown AVAssetWriter error.")
        }
        return PreparedSegment(writer: w, video: v, audio: a, url: url, markerURL: markerURL)
    }

    /// Throws away a prepared writer that never received a frame.
    nonisolated private static func discard(_ segment: PreparedSegment) {
        segment.writer.cancelWriting()
        try? FileManager.default.removeItem(at: segment.url)
    }

    /// Runs on the camera queue for the first frame of a segment. Only
    /// cheap work here: the writer is already started.
    private func beginSegment(at firstTime: CMTime, pixelBuffer: CVPixelBuffer) {
        guard writer == nil else { return }
        guard let segment = prepared else {
            if !reportedWriterFailure {
                reportedWriterFailure = true
                reportError("Recording could not start: the file was not prepared.")
            }
            return
        }
        prepared = nil

        segment.writer.startSession(atSourceTime: firstTime)
        do {
            try Data().write(to: segment.markerURL)
        } catch {
            reportError("Could not write the recovery marker: \(error.localizedDescription)")
        }

        writer = segment.writer
        videoInput = segment.video
        audioInput = segment.audio
        segmentStart = firstTime
        lastAudioPTS = .invalid
        lastAudioEnd = .invalid
        lastAudioReceivedPTS = .invalid
        pendingAudio.removeAll()
        framesSinceStats = 0
        cameraDropsLate = 0
        cameraDropsOutOfBuffers = 0
        cameraDropsOther = 0
        callFramesSkipped = 0
        callSkippedOnQueue = 0
        lastCallSkippedTotal = 0
        reportedCallBehind = false
        reportedMixMismatch = false
        currentMarkerURL = segment.markerURL
        isWriting = true
        droppedVideoFrames = 0
        droppedAudioBuffers = 0
        reportedWriterFailure = false
        reportedMissingAudio = false
        reportedDrops = false
    }

    private func finishSegment(completion: (() -> Void)? = nil) {
        guard let writer, isWriting else {
            completion?()
            return
        }

        drainAudio()
        pendingAudio.removeAll()
        isWriting = false
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let markerURL = currentMarkerURL

        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.currentMarkerURL = nil
        self.segmentStart = .invalid
        self.lastAudioPTS = .invalid

        writer.finishWriting { [weak self] in
            guard let self else { completion?(); return }
            self.writerQueue.async {
                if writer.status == .completed {
                    if let markerURL { try? FileManager.default.removeItem(at: markerURL) }
                } else {
                    self.reportWriterFailure(writer, prefix: "Recording could not be finalized")
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .captureFilesChanged, object: nil)
                }
                completion?()
            }
        }
    }

    private func reportWriterFailure(_ writer: AVAssetWriter, prefix: String) {
        guard !reportedWriterFailure else { return }
        reportedWriterFailure = true
        reportError("\(prefix): \(writer.error?.localizedDescription ?? "Unknown AVAssetWriter error.")")
    }

    private func reportWarning(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onWarning?(message) }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    // MARK: - Permissions

    private func requestPermissions() async throws {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard camera else { throw CaptureEngineError.cameraPermissionDenied }
        guard mic else { throw CaptureEngineError.microphonePermissionDenied }
        // AVAudioSession is configured by LiveKit (playAndRecord, videoChat,
        // speaker output, voice processing / echo cancellation).
    }

    // MARK: - Sample buffer helpers

    nonisolated private static func retime(_ sample: CMSampleBuffer, to pts: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: sample,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    nonisolated private static func makeAudioSampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: buffer.format.streamDescription,
                                             layoutSize: 0,
                                             layout: nil,
                                             magicCookieSize: 0,
                                             magicCookie: nil,
                                             extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                   dataBuffer: nil,
                                   dataReady: false,
                                   makeDataReadyCallback: nil,
                                   refcon: nil,
                                   formatDescription: formatDescription,
                                   sampleCount: CMItemCount(buffer.frameLength),
                                   sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing,
                                   sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                                                             blockBufferAllocator: kCFAllocatorDefault,
                                                             blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                             flags: 0,
                                                             bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sample
    }

    // MARK: - Files & recovery

    nonisolated static func directory() -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CaptureSegments", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// "segment-0007.mov" / "segment-0007-recovered.mov" -> 7
    nonisolated private static func segmentNumber(of url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("segment-") else { return nil }
        let digits = name.dropFirst("segment-".count).prefix { $0.isNumber }
        return Int(digits)
    }

    nonisolated private static func contents() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil)) ?? []
    }

    nonisolated private static func highestSegmentNumber() -> Int {
        contents().compactMap(segmentNumber(of:)).max() ?? 0
    }

    /// Finished (and recovered) recordings, oldest first. The file that is
    /// being written right now (it has a .recording marker) is excluded.
    nonisolated static func savedSegments() -> [URL] {
        let urls = contents()
        let active = Set(urls.filter { $0.pathExtension == "recording" }.compactMap(segmentNumber(of:)))
        return urls.filter { url in
            guard ["mov", "mp4"].contains(url.pathExtension), let n = segmentNumber(of: url) else { return false }
            return !active.contains(n)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Call ONCE at app launch, before anything records. A `.recording`
    /// marker left on disk means the app was killed while that file was
    /// being written. The fragmented movie is still playable up to the last
    /// fragment, so it is kept and renamed "...-recovered.mov".
    /// Returns the recovered files.
    nonisolated static func recoverInterruptedSegments() -> [URL] {
        let fm = FileManager.default
        var recovered: [URL] = []
        for marker in contents() where marker.pathExtension == "recording" {
            let base = marker.deletingPathExtension()
            let movie = base.appendingPathExtension(fileExtension)
            if fm.fileExists(atPath: movie.path) {
                let target = base.deletingLastPathComponent()
                    .appendingPathComponent(base.lastPathComponent + "-recovered")
                    .appendingPathExtension(fileExtension)
                try? fm.removeItem(at: target)
                if (try? fm.moveItem(at: movie, to: target)) != nil {
                    recovered.append(target)
                }
            }
            try? fm.removeItem(at: marker)
        }
        return recovered
    }
}

// MARK: - Microphone tap

/// Receives LiveKit's processed (echo-cancelled) microphone buffers.
nonisolated final class MicrophoneTap: NSObject, AudioRenderer, @unchecked Sendable {
    private let handler: (AVAudioPCMBuffer) -> Void
    init(handler: @escaping (AVAudioPCMBuffer) -> Void) { self.handler = handler }
    func render(pcmBuffer: AVAudioPCMBuffer) { handler(pcmBuffer) }
}

nonisolated final class AudioTimeline: @unchecked Sendable {
    // Gives microphone buffers continuous, sample-accurate host-clock
    // timestamps. Buffers are counted sample by sample from an anchor.
    // Delivery jitter and bursts (e.g. after a system stall) do NOT change
    // timestamps. Only an error that persists for a whole 1 s window is
    // corrected: behind real time -> jump forward (samples were really
    // lost), ahead of real time -> skip a few 10 ms chunks.
    private let lock = NSLock()
    private var next: CMTime = .invalid
    private var sampleRate: Double = 0
    private var inputLatency: CMTime = .zero
    private var skipBudget = 0
    private var windowStart: Double = 0
    private var windowMin: Double = .greatestFiniteMagnitude
    private var windowMax: Double = -.greatestFiniteMagnitude

    func reset() {
        let latency = AVAudioSession.sharedInstance().inputLatency
        lock.lock()
        next = .invalid
        sampleRate = 0
        skipBudget = 0
        windowStart = 0
        inputLatency = CMTime(seconds: latency, preferredTimescale: 1_000_000)
        lock.unlock()
    }

    /// Returns the presentation time for this buffer, or nil if the buffer
    /// should be skipped. Timestamps never go backwards.
    func timestamp(frames: AVAudioFrameCount, sampleRate rate: Double, arrival: CMTime) -> CMTime? {
        let scale = CMTimeScale(rate)
        let duration = CMTime(value: CMTimeValue(frames), timescale: scale)
        let arrivalSeconds = CMTimeGetSeconds(arrival)
        lock.lock()
        defer { lock.unlock() }

        // When the first sample of this buffer would have been captured if
        // it was delivered on time.
        let observed = CMTimeConvertScale(arrival - duration - inputLatency,
                                          timescale: scale,
                                          method: .roundHalfAwayFromZero)

        if !next.isValid {
            next = observed
            sampleRate = rate
            startWindow(arrivalSeconds)
        } else if rate != sampleRate {
            next = CMTimeMaximum(observed, CMTimeConvertScale(next, timescale: scale, method: .roundTowardPositiveInfinity))
            sampleRate = rate
            startWindow(arrivalSeconds)
        }

        let error = CMTimeGetSeconds(observed - next)
        windowMin = min(windowMin, error)
        windowMax = max(windowMax, error)

        if arrivalSeconds - windowStart >= 1.0 {
            if windowMin > 0.1 {
                // Behind real time for a full second: samples were lost.
                next = next + CMTime(seconds: windowMin, preferredTimescale: scale)
            } else if windowMax < -0.05 {
                // Ahead of real time for a full second: drift. Skip chunks.
                let chunk = Double(frames) / rate
                skipBudget = Int((-windowMax / chunk).rounded(.up))
            }
            startWindow(arrivalSeconds)
        }

        if skipBudget > 0 {
            skipBudget -= 1
            return nil
        }

        let pts = next
        next = pts + duration
        return pts
    }

    private func startWindow(_ at: Double) {
        windowStart = at
        windowMin = .greatestFiniteMagnitude
        windowMax = -.greatestFiniteMagnitude
    }
}

/// Collects the interviewer audio (LiveKit's mixed remote playout) and
/// adds it to the microphone chunks before they are written to the file.
///
/// Both streams arrive in 10 ms chunks on WebRTC's audio threads. A small
/// FIFO (max 150 ms) bridges them; if it runs dry the chunk gets silence for
/// the interviewer, if it overfills the oldest samples are dropped, so the
/// interviewer can never drift away from the user's voice.
nonisolated final class RemoteAudioMixer: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = 48_000
    private var ring: [Int16]
    private var readIndex = 0
    private var count = 0
    private var sampleRate: Double = 0
    private var formatText = "none"
    private var received = 0
    private var mixed = 0
    private var underruns = 0
    private var overflows = 0
    private var mismatch = 0
    private var peak: Int32 = 0

    override init() {
        ring = [Int16](repeating: 0, count: capacity)
        super.init()
    }

    func reset() {
        lock.lock()
        readIndex = 0
        count = 0
        received = 0
        mixed = 0
        underruns = 0
        overflows = 0
        mismatch = 0
        peak = 0
        lock.unlock()
    }

    func counters() -> (received: Int, mixed: Int, underruns: Int, overflows: Int, mismatch: Int, format: String, level: String) {
        lock.lock(); defer { lock.unlock() }
        let level = peak == 0 ? "silent" : String(format: "%.0f%%", Double(peak) / 327.67)
        peak = 0
        return (received, mixed, underruns, overflows, mismatch, formatText, level)
    }

    // AudioRenderer: interviewer audio, about to be played on the speaker.
    func render(pcmBuffer: AVAudioPCMBuffer) {
        let frames = Int(pcmBuffer.frameLength)
        let channels = Int(pcmBuffer.format.channelCount)
        guard frames > 0, channels > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        received += 1
        sampleRate = pcmBuffer.format.sampleRate
        formatText = "\(Int(sampleRate)) Hz \(channels) ch"

        let maxBuffered = Int(sampleRate * 0.15)
        for i in 0..<frames {
            var sum: Int32 = 0
            if let int16 = pcmBuffer.int16ChannelData {
                for c in 0..<channels { sum += Int32(int16[c][i]) }
            } else if let float = pcmBuffer.floatChannelData {
                for c in 0..<channels { sum += Int32(max(-1, min(1, float[c][i])) * 32767) }
            }
            let sample = Int16(clamping: sum / Int32(channels))
            peak = max(peak, abs(Int32(sample)))
            if count == capacity || count >= maxBuffered {
                readIndex = (readIndex + 1) % capacity   // drop oldest
                count -= 1
                overflows += 1
            }
            ring[(readIndex + count) % capacity] = sample
            count += 1
        }
    }

    /// Adds buffered interviewer samples to a microphone chunk, in place.
    func mix(into mic: AVAudioPCMBuffer) {
        let frames = Int(mic.frameLength)
        lock.lock()
        defer { lock.unlock() }
        guard received > 0 else { return }                 // no interviewer yet
        guard sampleRate == mic.format.sampleRate else { mismatch += 1; return }

        let n = min(count, frames)
        if n < frames { underruns += 1 }

        if let out = mic.int16ChannelData {
            let channels = Int(mic.format.channelCount)
            for i in 0..<n {
                let r = Int32(ring[(readIndex + i) % capacity])
                for c in 0..<channels {
                    out[c][i] = Int16(clamping: Int32(out[c][i]) + r)
                }
            }
        } else if let out = mic.floatChannelData {
            let channels = Int(mic.format.channelCount)
            for i in 0..<n {
                let r = Float(ring[(readIndex + i) % capacity]) / 32768
                for c in 0..<channels {
                    out[c][i] = max(-1, min(1, out[c][i] + r))
                }
            }
        } else {
            mismatch += 1
            return
        }
        readIndex = (readIndex + n) % capacity
        count -= n
        if n > 0 { mixed += 1 }
    }
}

// MARK: - Errors

enum CaptureEngineError: LocalizedError {
    case noCamera, cannotAddInput, cannotAddOutput, cannotAddWriterInput
    case unsupportedFormat(String)
    case writerStartFailed(String)
    case cameraPermissionDenied, microphonePermissionDenied, firstVideoFrameTimeout

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No front camera found."
        case .cannotAddInput: return "Could not add the camera input."
        case .cannotAddOutput: return "Could not add the camera output."
        case .cannotAddWriterInput: return "Could not configure the video/audio recording inputs."
        case .unsupportedFormat(let message): return message
        case .writerStartFailed(let message): return "Recording could not start: \(message)"
        case .cameraPermissionDenied: return "Camera permission denied. Enable it in Settings."
        case .microphonePermissionDenied: return "Microphone permission denied. Enable it in Settings."
        case .firstVideoFrameTimeout: return "The camera did not deliver a frame within 15 seconds."
        }
    }
}

extension Notification.Name {
    static let captureFilesChanged = Notification.Name("captureFilesChanged")
}
