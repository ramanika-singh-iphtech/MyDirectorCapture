import SwiftUI

struct CaptureView: View {

    // MARK: - View Model

    @StateObject private var model = CaptureViewModel()

    // LiveKit Cloud WebSocket URL.
    @State private var roomURL =
        "wss://mydirector-n2earnkr.livekit.cloud"

    // Room access token.
    // For the POC, this can be generated using the LiveKit CLI.
    @State private var token =
        "PASTE-YOUR-ROOM-TOKEN-HERE"

    // Used to detect when the app moves to background/inactive state.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {

        NavigationStack {

            VStack(spacing: 18) {

                // MARK: - Screen Title

                Text("MyDirector Capture POC")
                    .font(.title2.bold())

                // MARK: - Camera Preview

                // Camera preview is displayed only while
                // recording or paused.
                //
                // The preview uses the same AVCaptureSession
                // that is used for local recording.
                if model.isCameraOn || model.isRecording || model.isPaused {

                    CameraPreview(
                        session: model.captureSession
                    )
                    .frame(height: 400)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 16)
                    )
                }

                // MARK: - LiveKit Configuration

                // LiveKit Cloud project URL.
                TextField(
                    "LiveKit URL",
                    text: $roomURL
                )
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                // LiveKit room token.
                SecureField(
                    "LiveKit token",
                    text: $token
                )
                .textFieldStyle(.roundedBorder)

                // MARK: - Recording Status

                HStack {

                    // Status indicator:
                    // Gray   = Ready
                    // Red    = Recording
                    // Orange = Paused
                    Circle()
                        .fill(
                            model.isPaused
                            ? .orange
                            : (model.isRecording ? .red : .gray)
                        )
                        .frame(width: 10, height: 10)

                    Text(model.status)
                        .font(.subheadline)

                    Spacer()

                    // Shows the current recording duration.
                    Text(model.elapsed)
                        .monospacedDigit()
                        .font(.subheadline)
                }

                // LiveKit call state.
                Text(model.callStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // File health warning: shown only when the file being
                // written has a problem (out of sync, audio backing up,
                // dropped media). Hidden while everything is healthy.
                if !model.fileStats.isEmpty {
                    Text(model.fileStats)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // MARK: - Start / Resume

                if model.isPaused {

                    // Resume the existing recording session
                    // after an interruption such as a phone call
                    // or app backgrounding.
                    Button("Resume session") {

                        Task {
                            await model.resume()
                        }
                    }
                    .buttonStyle(.borderedProminent)

                } else {

                    // Start a new LiveKit + local recording session.
                    Button("Start") {

                        Task {
                            await model.start(
                                url: roomURL,
                                token: token
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    // Start remains disabled when:
                    // - A recording is already active
                    // - LiveKit URL has not been configured
                    // - A token has not been provided
                    .disabled(
                        model.isRecording ||
                        model.isStarting ||
                        roomURL.contains("YOUR-PROJECT") ||
                        token.contains("PASTE-")
                    )
                }

                // MARK: - Stop Recording

                // Stops both the local capture session
                // and the LiveKit room.
                Button("Stop") {

                    Task {
                        await model.stop()
                    }
                }
                .buttonStyle(.bordered)

                // Stop is available only while recording
                // or paused.
                .disabled(
                    !model.isRecording &&
                    !model.isPaused
                )

                // MARK: - Error Message

                // Display any error reported by the ViewModel.
                if let error = model.error {

                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }

                // MARK: - Saved Recording Segments

                List {

                    Section("Saved recording segments") {

                        // Each completed recording segment is
                        // displayed as a shareable MP4 file.
                        ForEach(
                            model.savedFiles,
                            id: \.self
                        ) { url in

                            // Allows the user to export/share
                            // the locally saved recording.
                            ShareLink(item: url) {

                                Label(
                                    "\(url.lastPathComponent)  ·  \(model.fileDurations[url] ?? "…")",
                                    systemImage: "video"
                                )
                            }
                        }
                    }

                    // MARK: - Recovery Information

                    Section("Recovery") {

                        Text(model.recoveryMessage)
                            .font(.footnote)
                            .foregroundStyle(
                                model.recoveryMessage.contains(
                                    "unfinished"
                                )
                                ? .orange
                                : .secondary
                            )
                    }
                }
            }
            .padding()
        }

        // MARK: - Initial File Check

        // Refresh saved recording files when the view
        // is initially loaded.
        .task {
            model.refreshFiles()
        }

        // MARK: - App Lifecycle

        // Detect background/inactive transitions.
        // CaptureViewModel decides whether the recording
        // needs to be paused.
        .onChange(of: scenePhase) { _, phase in
            model.appPhaseChanged(phase)
        }

        // MARK: - Recording Interruption Alert

        // Shows an alert when recording is automatically
        // paused because of an interruption.
        .alert(
            "Recording interruption",
            isPresented: $model.showInterruption
        ) {

            Button("OK", role: .cancel) {}

        } message: {

            Text(model.interruptionMessage)
        }
    }
}
