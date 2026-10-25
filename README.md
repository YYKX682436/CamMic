# CamMic

CamMic sends continuous iPhone microphone audio to a Mac so another Mac app can select it as a microphone input. It does not use iCloud, an Apple ID match, a SIM, an account, or an audio file. The iPhone remains in the foreground while capturing; entering the background stops capture and transport.

## Phase ①-2 architecture

- `CamMic/AudioCapture.swift` keeps the audio tap bounded. The callback copies borrowed PCM into a 12-slot preallocated pool (up to 16,384 frames per slot) and updates no files or network objects. In-flight audio is capped at 300 ms. `AVAudioConverter`, metering, framing, and sending run on a worker queue. A full pool or duration cap ends the session and drops the old data, with the failure view reporting which bound was hit.
- The shared wire format in `Shared/CamMicProtocol.swift` is versioned, length-limited, and uses a 16-byte session ID plus monotonically increasing frame sequence. Audio is 48 kHz, mono, signed PCM16 little-endian, 960 samples (20 ms / 1,920 bytes) per frame. The decoder accepts split and coalesced TCP data while bounding its memory.
- The iPhone listens on TCP port **50888** on the available interfaces. The Mac connects to the iPhone. Both sides use Network.framework TCP with an ephemeral eight-digit pairing code as a TLS-PSK. The code changes each time capture starts. Apple's Network.framework PSK API is limited to TLS 1.2, so both sides pin TLS 1.2 for this local link; see [Apple's Network framework migration note](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework?language=obj_5).
- The Mac accepts one iPhone session. It sends cumulative ACKs after the CoreAudio output callback has written a packet into the selected device's buffers. This does not measure when sound leaves the physical device. The iPhone has an eight-frame in-flight window, bounded to about 160 ms, and disconnects after a 1.25-second ACK stall. The microphone copy pool has twelve slots with a 300 ms frame budget, and its conversion consumer is ready before the audio engine starts producing tap buffers. The Mac output ring has twelve packets and outputs silence on underrun. Overflow, protocol errors, stop, and reconnect clear the session buffers.
- The Mac writes directly to the chosen output device by **device UID**; it re-resolves the current CoreAudio device handle at connection time and does not change the Mac's default output. `AVAudioConverter` converts to the selected device's sample rate. Mono samples are copied to left and right. Small occupancy-based sample correction limits clock-drift buildup. Device removal or format changes stop the session instead of switching to speakers.
- BlackHole 2ch is an external dependency. It is not copied, renamed, or bundled. The [official BlackHole project](https://github.com/ExistentialAudio/BlackHole) documents its installer and the Homebrew command `brew install blackhole-2ch`. Select BlackHole 2ch in CamMic Mac, then select **BlackHole 2ch** as the microphone input in QuickTime or another independent app. CamMic does not enable Mac speaker monitoring or route other system sounds into the selected device.

The pairing code is intended for a trusted local connection while CamMic is actively capturing. Avoid using it on a shared or untrusted network.

## Build

### iPhone IPA

The iOS deployment target remains **14.0**. The established build uses GitHub Actions `macos-14`, **Xcode 15.4 (15F31d)**, and the iOS 17.5 SDK. The workflow runs the R1 route-notification regression, the shared protocol tests, then creates an unsigned arm64 IPA. It uses no signing secrets. Use the existing 全能签 process to sign and install the IPA.

The same local script remains available on a Mac with Xcode 15.4:

```sh
DEVELOPER_DIR=/Applications/Xcode_15.4.app/Contents/Developer ./scripts/build-unsigned-ipa.sh
```

Output: `dist/CamMic-iOS14-unsigned.ipa` and `dist/build-report.txt`.

### Mac receiver

The Mac app uses Swift, AppKit, AVFoundation, CoreAudio, and Network.framework. This machine has Apple Silicon and Command Line Tools with a macOS SDK, but no full Xcode. The package builds locally with the installed Swift toolchain:

```sh
./scripts/build-mac-app.sh
```

Output: `dist/CamMic-Mac-arm64.app`, a commit-stamped `dist/CamMic-Mac-arm64-*.zip`, and `dist/mac-build-report.txt`. The app targets macOS 13.0 and is ad-hoc signed for local use; it is not Developer ID signed or notarized. The workflow also creates this arm64 app. BlackHole remains a separately installed driver.

### USB proxy

Install the official Homebrew libusbmuxd package if needed:

```sh
brew install libusbmuxd
iproxy --help
```

Then connect and unlock the XR, trust the Mac if iOS asks, obtain the XR UDID from Finder's device details, and run:

```sh
./scripts/run-iproxy-usb.sh <XR-UDID>
```

The script checks the installed `iproxy --help` syntax, selects that UDID and the USB channel, and binds only `127.0.0.1:50888`. Current libusbmuxd syntax uses `--local --udid <UDID> --source 127.0.0.1 50888:50888`; the legacy positional syntax is handled separately. It does not replace or modify macOS's system usbmuxd. A proxy process or open port alone is not a successful USB test: the Mac app must complete TLS pairing and the CamMic protocol handshake through it.

## Connect and verify

1. Install `dist/CamMic-iOS14-unsigned.ipa` through 全能签 with the existing signing setup. Do not change the bundle ID unless the provisioning profile requires it. Allow microphone and Local Network permissions when iOS asks.
2. Install BlackHole 2ch separately using the official installer or Homebrew. In the Mac receiver, refresh devices and select BlackHole 2ch. If BlackHole is missing, the app does not connect or fall back to speakers.
3. For Wi-Fi, keep the iPhone and Mac on the same local network. On iPhone, open **Settings → Wi-Fi → (i)** and use the iPhone's IP address in CamMic Mac. On Mac, allow the local-network prompt if shown.
4. Open CamMic on the iPhone, tap **开始采音并等待 Mac**, and leave it in the foreground. The app displays a new eight-digit code and port 50888. If startup fails, it presents the failing stage and system error. Enter the iPhone IP and code in CamMic Mac, then connect.
5. In QuickTime Player, open **File → New Audio Recording**, choose **BlackHole 2ch** in the input menu, speak near the iPhone, and make a recording. Playback must contain the XR voice and not Mac system sounds. A changing level meter or a connected status alone is not this acceptance test.
6. For a USB-only test, turn Wi-Fi off on the iPhone in Settings, keep USB connected and the proxy running, enter `127.0.0.1` in CamMic Mac, and connect again. The app handshake must succeed. Then unplug and reconnect the cable; the old session must go silent and must not play buffered voice after reconnection.
7. Run a ten-minute QuickTime recording. At the beginning and end, record the Mac display's output queue (frames, packets, and estimated queued milliseconds), received packet count, protocol/buffer anomalies, and underrun callback count. The iPhone displays **Mac audio device callback ACK RTT** average and maximum. It is measured on one iPhone monotonic clock from sending an audio frame until the Mac confirms the CoreAudio callback wrote it into the selected device's buffers. It includes both network directions and queueing; it is **not one-way latency or physical acoustic output latency**. Do not subtract timestamps from unsynchronized devices.
8. Stop, reconnect, and repeat. Stopping or losing a route, cable, or network should immediately silence and clear the session. Return to the foreground and start again for a new pairing code.

## Regression coverage

- `CamMicTests/RouteChangeTests.swift` remains the R1 regression. It posts route notifications from a background queue, verifies main-thread stop handling, ignores startup category changes, and checks repeated notifications.
- `CamMicTests/AudioCaptureQueueTests.swift` verifies bounded slot and duration limits, large tap-buffer handling, coalesced diagnostics, and a prestarted consumer draining more than one pool's worth of audio.
- `SharedTests/CamMicProtocolTests.swift` covers split/coalesced TCP frames, oversized lengths, wrong session IDs, sequence gaps, and the cumulative in-flight ACK window.
- GitHub Actions runs the route and audio-queue regressions, the shared protocol suite, and builds the iOS IPA and Mac app. Local `swift build` is available here. This machine has no Xcode/XCTest runtime, so iOS tests must be executed by Actions.

## Verification status

- **XR live capture and QuickTime:** PASS on iPhone XR / iOS 14.3 using the ①-2 capture build. The user spoke a test phrase; QuickTime's input level rose with **BlackHole 2ch** selected, and QuickTime saved a 12:18, 48 kHz stereo AAC recording. The file was saved locally as `CamMic-USB-QuickTime-10min.m4a` and is not committed. Playback clarity and the absence of unrelated system audio still require the user's listening confirmation.
- **USB transport:** PASS through official Homebrew libusbmuxd 2.1.1 `iproxy --local --udid … --source 127.0.0.1 50888:50888`, bound only to `127.0.0.1:50888`. TLS pairing and the CamMic protocol handshake completed with the XR; after the user unplugged and reconnected the cable, a fresh handshake and audio packets succeeded. The phone's Wi-Fi toggle state was not independently captured, but the tested path was the local USBMux proxy, not a Wi-Fi IP.
- **Ten-minute USB stability:** PASS. During the measured ten-minute window, Mac received packets increased from 7,099 to 39,999, protocol anomalies stayed at 0, and the BlackHole output queue ranged from 25 to 51 ms (1,219–2,452 frames at 48 kHz). Underrun callbacks remained at 5 throughout that window. CamMic Mac RSS was about 108 MB mid-run and 94 MB afterward; it did not grow over time. The displayed playback queue is not end-to-end or one-way latency; the iPhone ACK RTT uses one iPhone monotonic clock and includes both network directions and CoreAudio queueing.
- **Stop, restart, and session isolation:** PASS. Stopping Mac output muted and cleared its ring; reconnecting within the same phone run started fresh receive/consume counters. Stopping and restarting iPhone capture invalidated the old pairing, the old Mac connection ended, and entering the new code established a fresh session. The latest Mac build displays 0 frames / 0 packets / 0 ms after disconnect.
- **Mac output routing:** BlackHole 2ch 0.7.1 was enumerated at 48 kHz/two channels and selected in both CamMic Mac and QuickTime. Mac mini speakers remained the global default output, and CamMic does not enable speaker monitoring. No separate test tone was injected into macOS system audio during the recording; the user is checking the saved recording for any audible system sound.
- **CI:** PASS on commit `fd159b4` (Actions run [40172675293](https://github.com/YYKX682436/CamMic/actions/runs/40172675293)): R1 route and audio queue regressions, protocol/session regressions, iOS 14.0-minimum unsigned arm64 IPA, and arm64 Mac app all built successfully with Xcode 15.4 / macOS 14. The final documentation commit is checked by Actions as well.
- **Wi-Fi transport:** Implemented but not real-device tested in this run; USB was the measured channel.

No camera, automatic discovery, automatic path switching, or final UI design is included in this phase.
