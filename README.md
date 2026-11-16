# MyDirector iOS Capture POC

Native Swift / SwiftUI proof of concept for the MyDirector interview recording
flow.

**The question this POC answers:** can one iPhone camera and microphone feed a
live LiveKit call **and** a full-quality local file at the same time, reliably,
for a whole interview?

---

## Current status

| Area | Status |
|---|---|
| End-to-end on device (call + local recording) | ✅ Working on a real iPhone (iOS 26.6.1) |
| Same camera frames → LiveKit call + local file | ✅ Working, verified on device |
| Local file ≥1080p, 30 fps, H.264, AAC audio | ✅ Verified: 1080×1920, 30.0 fps, 0 dropped frames |
| File length matches the session | ✅ Verified: timer 00:32 → 32.10 s, timer 00:36 → 36.94 s |
| User's voice clear in the file (echo-cancelled mic) | ✅ Verified on device |
| Audio/video sync | ✅ Passed: in sync over the 10-minute session (short runs measured at +16 to +41 ms) |
| Interviewer voice in the file | ✅ Working on device: mixed with the user's voice (see [Interviewer audio](#interviewer-audio-in-the-file)). Beyond the brief. |
| Scenario A – 10-minute session | ✅ Passed on device |
| Scenario B – phone call | ✅ Passed on device |
| Scenario C – background / screen lock | ✅ Passed on device |
| Scenario D – force-quit | ✅ Passed on device |
| Scenario E – background upload (optional) | ❌ Not implemented |
| Scenario F – 20-minute heat (optional) | ⏳ Not run |

---

## Setup and how to run

### 1. Requirements

| Item | Version / note |
|---|---|
| Mac with Xcode | Xcode 26 |
| iPhone | Real device, iOS 17.6+ (the camera can't be tested on the simulator) |
| Apple developer account | Any free or paid team, for signing onto the device |
| LiveKit Swift SDK | 2.19.0 (fetched automatically by Swift Package Manager) |
| LiveKit Cloud project | Free tier is enough – <https://cloud.livekit.io> |
| LiveKit CLI (`lk`) | To create tokens (see below) |

### 2. Create the LiveKit Cloud project

1. Sign in at <https://cloud.livekit.io> and create a project (this POC uses
   `mydirector`).
2. Note the project's **WebSocket URL**, e.g.
   `wss://mydirector-n2earnkr.livekit.cloud`. It's under Project Settings, and
   it's what the app's "LiveKit URL" field needs.

### 3. Install and link the LiveKit CLI

```bash
# macOS
brew install livekit-cli

# Link the CLI to your LiveKit Cloud project (opens the browser to sign in)
lk cloud auth

# Check the project is linked and is the default (marked with *)
lk project list
```

Alternative without browser sign-in: use the API key and secret from the
project's settings.

```bash
lk project add mydirector \
  --url wss://mydirector-n2earnkr.livekit.cloud \
  --api-key <API_KEY> \
  --api-secret <API_SECRET>
lk project set-default mydirector
```

> Never put the API **secret** in the app or in the repository. The app only
> needs a **token**.

### 4. Generate the tokens – one per participant

LiveKit allows **one participant per identity** in a room. The phone and the
browser must therefore use **two different tokens with different
identities**. With the same token on both, they keep kicking each other out of
the room (the app shows a "same identity" error when this happens).

```bash
# Token for the iPhone app
lk token create \
  --join \
  --room mydirector-poc \
  --identity iphone-user \
  --valid-for 24h \
  --token-only

# Token for the browser / interviewer
lk token create \
  --join \
  --room mydirector-poc \
  --identity browser-interviewer \
  --valid-for 24h \
  --token-only
```

- `--join`: allows joining the room and publishing and subscribing to
  audio/video.
- `--room`: must be the **same room** for both tokens.
- `--identity`: must be **different** for each participant.
- `--valid-for`: how long the token works (e.g. `24h`). Create new tokens when
  they expire.
- `--token-only`: prints only the token, ready to paste.

Shortcut for the browser side: `--open meet` (instead of `--token-only`) opens
LiveKit Meet with the token already filled in.

**Check which identity a token has** (optional). The middle part of the token
is base64 JSON:

```bash
echo '<TOKEN>' | cut -d. -f2 | base64 -d 2>/dev/null; echo
# → {"sub":"iphone-user", ... "video":{"room":"mydirector-poc","roomJoin":true}}
```

### 5. Join as the interviewer (browser)

1. Open LiveKit Meet: <https://meet.livekit.io>, then the **Custom** tab.
2. **LiveKit Server URL:** `wss://mydirector-n2earnkr.livekit.cloud`
3. **Token:** the `browser-interviewer` token.
4. Join, **allow the microphone** and keep it **unmuted**.
5. To act as the AI interviewer, play speech on the computer so the browser's
   microphone picks it up. The phone then plays the interviewer from its
   speaker.

### 6. Build and run the app on the iPhone

1. Connect the iPhone and open `MyDirectorCapture.xcodeproj` in Xcode.
2. Target **MyDirector** → **Signing & Capabilities** → choose your **Team**
   (change the bundle identifier if needed).
3. Choose the iPhone as the run destination and press **Run** (⌘R). The first
   time, trust the developer on the phone under Settings → General → VPN &
   Device Management.
4. In the app:
   - **LiveKit URL:** `wss://mydirector-n2earnkr.livekit.cloud` (already filled
     in).
   - **LiveKit token:** paste the `iphone-user` token.
5. Tap **Start**. Allow **camera** and **microphone** access. The status goes
   through *Starting camera…*, *Connecting to LiveKit…*, *Waiting for the call
   video to settle…*, *Preparing the recording file…*, then *Recording + LiveKit
   connected*.
6. Tap **Stop** to finish the file. Saved recordings are listed in the app
   with their duration. Tap one to share it (AirDrop, Files, …).

### 7. Check that both participants are in the room

```bash
lk room list
lk room participants list mydirector-poc
```

You should see both `iphone-user` and `browser-interviewer`. Run
`lk room --help` if your CLI version uses different subcommands.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The browser drops out when the phone joins (or the other way round); the app says "same identity" | Both use a token with the same identity | Create two tokens with different `--identity` values |
| Start fails with an authentication / token error | Token expired, wrong room, or from another project | Create a new token with `lk token create` for the right project |
| The interviewer can't hear the user | The phone's mic permission was denied | iPhone Settings → MyDirector → Microphone on |
| The phone doesn't hear the interviewer | The browser mic is muted or not allowed | Unmute in Meet and allow the microphone in the browser |
| The first Start takes 10–25 s | iOS sets up the video encoders on the first run after launch | Wait; later Starts take about 3 s. The file isn't affected |
| "Recording is not working" after many tests | Phone storage is full (about 75 MB per minute) | Delete old recordings from the app's folder or free up space |

---

## Architecture

Each device has exactly **one owner**:

```text
 Front camera (opened once)                          Microphone
          |                                               |
 AVCaptureSession (video only)                  LiveKit / WebRTC audio engine
          |                                     (Apple voice processing:
   1080x1920 frames, 30 fps                      echo cancellation, AGC, NS)
          |                                               |
   camera queue (only quick work)               +---------+-----------+
     |                     |                    |                     |
 AVAssetWriter       call queue (max 2)     local audio renderer   LiveKit mic track
 (prepared ahead)    720p copy (VideoToolbox) (same processed audio) (call audio)
     |                     |                    |                     |
 local .mov  <-------------+------- AAC ---------+                LiveKit room
                     LiveKit BufferCapturer → LiveKit room       |
                                                                 | interviewer audio
                                          remote audio renderer <-+ (played on speaker)
                                          → RemoteAudioMixer → mixed into the mic
                                            audio before it is written to the file
```

- **Camera:** one `AVCaptureSession`, front camera, 1080p locked to 30 fps.
  Frames are rotated to upright portrait (1080×1920), so no transform is needed
  in the file or the call.
- **The same frames go to both outputs:**
  - **File:** the original camera frame goes straight to `AVAssetWriter`.
  - **Call:** a 720p copy of the same frame, scaled with VideoToolbox, is handed
    to LiveKit's `BufferCapturer` on its own queue. At most 2 frames are in
    flight. If the call falls behind, only the call skips frames; the file is
    never blocked.
- **Microphone:** owned only by LiveKit. The file records the **same processed
  (echo-cancelled) microphone audio** the call sends, through
  `AudioManager.shared.add(localAudioRenderer:)`. The mic is *not* added to the
  `AVCaptureSession`.
- **Interviewer:** the interviewer's audio, as the phone plays it, is taken
  from `AudioManager.shared.add(remoteAudioRenderer:)` and mixed into the
  microphone audio before it's written. The file has **both voices**.
- **Timestamps:** video and audio are both on the host clock. Audio timestamps
  are counted sample by sample, so delivery jitter and bursts don't move them.
  Only an error that lasts for a full second is corrected (a jump forward if
  samples were lost, a small skip if the timeline runs ahead). Timestamps never
  go backwards.
- **File writer:** created and started (`startWriting`) on a background queue
  *before* recording starts. The camera queue only calls
  `startSession(atSourceTime:)` on the first frame.

### Local file

| Setting | Value |
|---|---|
| Resolution | 1080 × 1920 (portrait) |
| Frame rate | 30 fps (camera locked) |
| Video | H.264 High, ~10 Mbps, key frame every 30 frames |
| Audio | AAC, 48 kHz, mono, 128 kbps |
| Container | QuickTime `.mov`, **fragmented every 2 s** (`movieFragmentInterval`) |
| Size | ~75 MB per minute (~750 MB for 10 min) |

One file is written per continuous run. A pause (phone call, background) ends
the file and Resume starts the next one: `segment-0001.mov`, `segment-0002.mov`,
and so on.

---

## Audio

- LiveKit manages the `AVAudioSession`: `playAndRecord`, mode `videoChat`,
  speaker output (confirmed in the logs: `out Speaker`).
- Microphone capture options: echo cancellation, auto gain control, noise
  suppression, high-pass filter.
- Echo cancellation stays on, so the interviewer's voice from the speaker isn't
  sent back into the call.
- **What the file sounds like:** the **user's voice, clear** (echo-cancelled,
  gain-controlled, noise-suppressed, exactly as the call hears it) **plus the
  interviewer's voice**, mixed into one audio track. The interviewer is mixed
  in digitally from the call, not picked up from the speaker, so it's clean
  and has no room echo. Echo cancellation still removes the speaker sound from
  the microphone, so the interviewer isn't recorded twice and isn't sent back
  into the call.

### Interviewer audio in the file

Beyond the brief (which only asks for the user's voice), but useful for
editors cutting interview clips.

**How it works (`RemoteAudioMixer` in `CaptureEngine.swift`):**
1. LiveKit hands the app the interviewer's audio (all remote participants, as
   played on the phone's speaker) in 10 ms chunks through
   `AudioManager.shared.add(remoteAudioRenderer:)`.
2. The chunks go into a small buffer (at most 150 ms). Stereo is turned into
   mono.
3. Each 10 ms microphone chunk takes the same number of interviewer samples
   from the buffer and adds them to the user's voice, clipping-safe. The mix is
   done on the app's own copy of the audio, so **the call's audio isn't
   changed**.
4. If no interviewer audio is waiting (nobody speaking, or no remote
   participant), the chunk keeps just the user's voice. If the buffer
   overfills, the oldest samples are dropped, so the interviewer can never
   drift away from the user's voice.

**Properties and limits:**
- **One mixed mono track:** user and interviewer are in the same audio track.
  They can't be separated later in editing. A second, separate track per voice
  would be possible if editors need it.
- **Alignment:** the interviewer is aligned to within about 150 ms (normally a
  few tens of ms) of when they were heard on the phone.
- **All remote participants are mixed together:** this is designed for one
  interviewer.
- **Format check:** if the interviewer's audio format doesn't match the
  microphone's (sample rate), mixing is skipped and the app shows a warning.
  The file then has the user's voice only.

**Earlier "silent interviewer" during testing:** during setup the interviewer
part of the file was silent. The cause was the browser not sending audio into
the room: phone and browser shared the same token and kept kicking each other
out, and the browser mic was muted. With separate tokens and the browser mic
on, the interviewer is recorded.

---

## Session flow

**Start**
1. Camera starts; the preview appears right away. Nothing is written yet.
2. Connect to LiveKit, enable the microphone, publish the 720p video track.
3. Wait until the camera runs smoothly (2 s without dropped frames). Starting
   the call's encoder can briefly stall the camera.
4. Prepare the file writer in the background.
5. Open the file and start the timer **at the same moment**, so the file length
   matches the timer.

**Pause** (phone call / audio interruption, app inactive or in background,
camera interrupted)
- The timer stops, the camera stops and the current file is finished cleanly.
  The app asks iOS for background time so saving completes.
- The LiveKit mic is muted. The app shows *Paused* and the reason.
- With the **Audio background mode**, the app (and the call) stays alive in the
  background. iOS does not allow the camera in the background, so video pauses.

**Resume** (one tap)
1. Back in the call: wait up to 15 s for LiveKit's own reconnect. If the room is
   gone, join the **same room** again and republish camera and mic.
2. Turn the mic back on and check that audio really arrives. After a phone
   call, restart it once if needed.
3. Prepare the next file in the background, restart the camera, continue.

**Call drops during recording:** the app rejoins the same room automatically.
The local recording continues.

**Duplicate identity:** if LiveKit removes the phone because another device
joined with the same identity, the app does **not** rejoin (that would kick the
other device). It shows a clear message instead.

**Stop:** finish the file (with background time), leave the room, refresh the
file list.

---

## Crash recovery (scenario D)

- While a file is being written, a `segment-NNNN.recording` marker sits next to
  it.
- The movie is fragmented every 2 s, so after a force-quit the file is still
  playable up to the last fragment (at most about 2 s lost).
- At the next launch, a leftover marker means the app was killed mid-recording.
  The file is kept, renamed to `segment-NNNN-recovered.mov`, and the app shows
  *"An unfinished recording was found"*.

---

## No silent failures

Shown on screen:
- Camera or microphone permission denied.
- Camera runtime error or interruption.
- Camera dropping frames (15 or more while recording).
- Writer start, write and finish failures.
- **No microphone audio reaching the file for 2 s.**
- Recorder dropping media (writer can't keep up).
- LiveKit disconnect, failed rejoin, duplicate identity.
- Mic not coming back after an interruption.
- **Call video falling behind** (frames skipped for the call).
- Interviewer audio format mismatch.

While recording, an orange status line appears **only if the file has a
problem**: audio and video more than 100 ms out of sync, more than 0.5 s of
audio waiting, or any dropped audio or video. For example:
`File A/V: +240 ms · audio queued 0 · dropped A 0 / V 3`. When everything is
healthy, the line is hidden.

---

## Test scenarios

All required scenarios (A–D) were run on a real iPhone (iOS 26.6.1) with a
browser interviewer in the same LiveKit room, and **passed**. Screen recordings
of each run are delivered separately.

### A — 10-minute session — ✅ passed
- 10-minute call with the interviewer (browser) in the room.
- The local file is about 10 minutes long, 1080×1920 at 30 fps, H.264 + AAC.
  It has the user's voice clear plus the interviewer, in sync, and plays
  without errors.
- The other side saw and heard the user the whole time.
- Measured on earlier sessions: 0 dropped camera frames while recording, file
  length equal to the timer, audio/video offset steady at +16 to +41 ms.

### B — Phone call in the middle — ✅ passed
- At minute 3 a phone call came in and was taken for about 30 s.
- The app paused (camera stopped, file finished cleanly) and showed *Paused*.
- After hanging up, **Resume** rejoined the same room, the microphone came
  back, and recording continued in a new numbered file.
- Result: two files (before and after the call), nothing lost before the call.

### C — Background / screen lock — ✅ passed
- At minute 5 the app went to the home screen for 20 s, came back and resumed
  with one tap. The same was done with the lock button.
- The call stayed connected (Audio background mode); the file before the
  interruption was finished cleanly, and a new file started on Resume.
- **iOS limit:** the camera can't run in the background, so video pauses while
  the app is away and the other side sees a paused picture. Audio and the call
  connection continue.

### D — Force-quit — ✅ passed
- At minute 6 the app was force-quit (swiped away) while recording.
- On reopening, the app showed that an unfinished recording was found and
  listed it as `segment-NNNN-recovered.mov`.
- The recovered file plays up to a few seconds before the force-quit (2-second
  fragments).

### E — Background upload — ❌ not implemented
Optional, not part of this POC. Approach for production: a background
`URLSession` with multipart pre-signed URLs (S3 or GCS) uploading the 2-second
fragments or fixed-size parts. Retry only the failed part, and mark done after
the server confirms completion.

### F — Heat / 20 minutes — ⏳ not run
By design the call degrades first (720p, adaptive, frames skipped only for the
call) and the file keeps its fixed 1080p30 quality.

---

## Problems found and fixed during the POC

| Symptom | Cause | Fix |
|---|---|---|
| 10 s recording → ~40 s file, black stretches, only "echo" audio | Mic used twice (camera session + LiveKit). LiveKit reconfigured the audio session, the camera session's clock jumped, and the file got raw speaker sound | One mic owner (LiveKit); the file records LiveKit's processed mic; host-clock timestamps |
| Frozen start (5–8 s with no video), voice missing afterwards | `AVAssetWriter.startWriting()` took **5.2–10.8 s** on the device and ran on the camera queue, so the camera ran out of buffers | Writer prepared on a background queue before recording; camera queue does only quick work |
| Camera stalls while the call starts | Camera buffers handed to LiveKit; the 720p scaler created on the camera queue (2.3 s once) | LiveKit gets its own 720p copy on its own queue (max 2 in flight); scaler created ahead of time |
| File started before the camera preview appeared | File and timer opened before the call setup finished | Camera first, then the call, then file and timer together |
| Audio skipped after a stall | Audio timeline treated a delivery burst as drift | Correct only errors that last 1 s |
| Interviewer and phone kept dropping | Same token (same identity) on both devices | Separate tokens; the app detects duplicate identity and doesn't fight it |
| Interviewer missing from the file | The file only had the echo-cancelled mic, and echo cancellation removes the interviewer coming from the speaker | Interviewer audio taken from the call (remote audio renderer) and mixed into the file's audio |

---

## Known limitations and risks

1. **iOS background:** the camera can't run in the background. A background or
   lock event always pauses video and starts a new file.
2. **Unexpected termination:** up to about 2 s (one fragment) can be lost after
   a force-quit or crash.
3. **Slow first start:** on a cold start, `startWriting` took up to 10.8 s and
   Start took about 26 s in total. It doesn't affect the file (it happens before
   recording), but the user waits. Warming up the writer at app launch would
   help.
4. **Long sessions and heat:** two hardware encoders, the scaler and the network
   run at the same time. The 20-minute test is still to be run.
5. **Sync over longer interviews:** confirmed for 10 minutes. Sessions much
   longer than that (30–60 min) haven't been tested yet.
6. **Interviewer audio** is mixed into one track with the user. Editors can't
   separate the two voices. With several remote participants, all are mixed
   together.
7. **Token handling:** tokens are pasted manually for the POC. Production needs
   a backend that issues one token per participant.

---

## Why We Have Created the Initial Demo Using SwiftUI Instead of React Native / Expo

We have created the initial demo using native iOS (SwiftUI) rather than React Native / Expo because the most challenging part of this implementation involves low-level iOS media processing.

The core functionality requires managing a single AVCaptureSession that feeds two encoders, synchronizing audio and video through AVAssetWriter, handling media timing and fragmentation, managing the audio session and voice processing alongside WebRTC, and correctly handling interruptions and background behaviour.

These operations require direct, synchronous access to native sample buffers, AVFoundation APIs, audio hardware, and device-managed execution queues. Implementing this pipeline directly in Swift allows us to avoid unnecessary JavaScript bridge communication in the real-time media-processing path and gives us better control over performance, timing, resource management, and debugging.

The objective of creating this demo in SwiftUI is to first validate the core native media architecture independently, identify and resolve low-level iOS issues, and ensure that audio/video capture, encoding, synchronization, and interruption handling work reliably before introducing React Native / Expo integration.

Once the native implementation is stable, we can package the capture engine as a reusable native Swift module and integrate it into our production React Native / Expo application.

The React Native / Expo layer will only need to interact with a simple set of native methods:

Start recording

Stop recording

Pause recording

Resume recording

Receive recording status and error events

This approach allows us to validate and stabilize the most technically challenging component first, rather than introducing React Native / Expo integration as an additional variable while debugging native media-processing issues.

In short: We are using SwiftUI for the initial demo not because React Native / Expo cannot support this functionality, but because validating the native iOS recording engine independently is the most reliable first step. Once validated, the same native engine can be integrated into our React Native / Expo production application without rewriting the core media-processing logic.

---

## Project structure

| File | Purpose |
|---|---|
| `CaptureEngine.swift` | Camera session, 720p call copy, file writer (prepared ahead, fragmented), microphone tap and audio timeline, interviewer audio mixer (`RemoteAudioMixer`), crash recovery |
| `CaptureViewModel.swift` | LiveKit join/rejoin, start/pause/resume/stop flow, interruptions and app lifecycle, background time, errors and status for the UI |
| `CaptureView.swift` | Single screen: preview, LiveKit URL and token fields, Start/Resume/Stop, status, file-health warning, saved recordings, recovery message |
| `CameraPreview.swift` | Camera preview layer |
| `Info.plist` | `UIBackgroundModes = audio` (merged with the generated Info.plist) |

---

## Repository notes

Recordings and local files must not be committed. Suggested `.gitignore`:

```gitignore
*.mov
*.mp4
*.log
.DS_Store
xcuserdata/
DerivedData/
```

No LiveKit API key, secret or token is stored in the code. Tokens are pasted
into the app at runtime.
