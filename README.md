# CamMic

CamMic sends live iPhone microphone audio to a Mac. The Mac publishes one dedicated system input device named **CamMic**. Other Mac apps, including QuickTime Player, can select CamMic as their microphone. The CamMic Mac app writes to a hidden, output-only endpoint; it does not change the Mac's default speakers or route system audio into the microphone.

The iPhone app keeps its existing local-network and USB transport, TLS-PSK pairing, session isolation, bounded PCM queues, and silence-on-underrun behavior. iOS continues to require **14.0 or later**. The existing app Bundle IDs are unchanged.

## Existing audio transport

- `CamMic/AudioCapture.swift` copies microphone PCM into a 12-slot preallocated pool, with a 300 ms in-flight limit. Conversion, metering, framing, and sending run on a worker queue. Overflow or reaching the duration limit ends the session and drops queued audio.
- The conversion worker drains each accepted input block before reusing its slot and joins samples into complete transport frames. `Shared/CamMicProtocol.swift` uses a versioned, length-limited format with a 16-byte session ID and increasing frame sequence. Audio frames contain 960 samples at 48 kHz, mono, signed PCM16 little-endian (20 ms / 1,920 bytes).
- The iPhone listens on TCP port **50888**. The Mac connects to it over Network.framework using an ephemeral eight-digit pairing code as a TLS-PSK. The code changes when capture starts; both sides pin TLS 1.2 for Network.framework's PSK support. Use the pairing code only on a trusted local connection while CamMic is actively capturing.
- The Mac accepts one phone session and sends cumulative acknowledgements after the CoreAudio callback consumes a packet. The iPhone limits unacknowledged audio to eight frames (about 160 ms) and disconnects after a 1.25-second acknowledgement stall. The Mac output ring is limited to twelve packets and writes silence on underrun. This acknowledgement is not a measurement of physical acoustic output latency.
- Both real-time callbacks avoid waiting on shared state. The Mac callback clears output and returns silence if it cannot acquire renderer state; queue contention has a separate counter from ordinary underruns. Stop, overflow, protocol errors, disconnect, and reconnect clear session audio.
- Listener and connection callbacks carry generation/session identity so delayed callbacks from an earlier session cannot alter a replacement session. Receive decoders and acknowledgement windows are scoped to their connection.

## Mac audio device architecture

- The CamMic HAL driver is built from the official BlackHole v0.7.1 source at commit [`e2b22aaaba4e507a097131704bf96dabc004d9cf`](https://github.com/ExistentialAudio/BlackHole/tree/e2b22aaaba4e507a097131704bf96dabc004d9cf). Its source, exact patch, fixed build configuration, and license are retained in this repository.
- The public input-only device is `CamMic`, UID `CamMic2ch_UID`. It has two input channels and no output channels.
- The hidden output-only endpoint is `CamMicInternalOutput`, UID `CamMic2ch_2_UID`. The Mac receiver writes mono phone audio into both output channels.
- The model UID is `CamMic2ch_ModelUID`, the HAL bundle ID is `com.yykx682436.CamMicAudioDriver`, the bundle path is `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver`, and the plug-in factory UUID is `4b469f5a-1284-4ac8-b82c-75026d5ae711`. These values stay fixed across upgrades. They are distinct from the original BlackHole identities, so both drivers can be installed together.
- `AudioDeviceCatalog.device(uid:)` resolves the hidden endpoint with `kAudioHardwarePropertyTranslateUIDToDevice`; it does not enumerate visible output devices. Output channel layout and stream format are checked with output scope. The public microphone is resolved separately, with channel and stream-format checks in input scope. The receiver repeats both checks while connected and stops, mutes, and clears its ring if either endpoint disappears, is replaced, or changes direction/format.
- The app's component status shows whether both CamMic endpoints are ready. It never asks the user to select BlackHole or an arbitrary output. If the driver is missing, **Install or Repair Audio Component** opens the driver-only installer bundled inside `CamMic.app`.

## Install on macOS

Download the `CamMic-Step1-<commit>` artifact from the successful GitHub Actions run for the desired commit. The `CamMic-macOS-arm64-<commit>.zip` contains the named app, the combined installer, the standalone driver installer, source, notices, and uninstall/recovery scripts. The Actions artifact also contains the unsigned iOS IPA and build reports.

1. Unzip the Mac archive and quit CamMic and any app currently recording audio.
2. Open `CamMic-Installer.pkg` and follow the macOS administrator prompts. The package installs `/Applications/CamMic.app` and only `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver` for the driver. It restarts `coreaudiod`; audio apps may briefly lose their audio route during this step.
3. Open **CamMic**. Its status should report `系统麦克风：CamMic` and that the internal output is ready.
4. In QuickTime Player, choose **File → New Audio Recording**, open the input menu, and select **CamMic**. QuickTime may request microphone permission.

The installer backs up an existing CamMic app and driver before replacement and validates the installed bundle identities. A failed install restores the previous files when the installer can run its recovery step. If installation stops after changing files, the recovery copy and state remain under `/Library/Application Support/CamMic/Recovery/`; run `restore-cammic-install.sh` from the archive to restore it. A new installation is refused while an earlier recovery is pending, so it cannot replace the recovery pointer. A successful upgrade removes the previous app at `/Applications/CamMic-Mac-arm64.app` only when that bundle has CamMic's former bundle ID.

The installer, app, and driver are not Developer ID signed or notarized. The Mac app and HAL driver have local ad-hoc code signatures; the package is unsigned. macOS may require the user to confirm opening the downloaded installer. No Apple signing credentials or notarization credentials are included.

## Install the iPhone app

`CamMic-iOS14-unsigned.ipa` is arm64 and unsigned. Install it with the existing 全能签 flow and its existing provisioning setup. The app Bundle ID remains `com.yykx682436.CamMic`. Allow microphone and local-network access when asked. The workflow does not use signing secrets.

## Connect over USB

The current manual USB path uses the existing USBMux proxy; automatic USB pairing remains outside this step. Install the official Homebrew `libusbmuxd` package if needed, connect and unlock the iPhone, trust the Mac if iOS asks, and get the XR UDID from Finder's device details. Then run:

```sh
./scripts/run-iproxy-usb.sh <XR-UDID>
```

The proxy binds only `127.0.0.1:50888`; the Mac app connects to `127.0.0.1` using the pairing code shown on iPhone. A proxy process or open port alone does not prove a working audio path; complete the TLS and CamMic protocol handshake and record through QuickTime.

## Uninstall CamMic

Run `uninstall-cammic.sh` from the downloaded Mac archive or this repository:

```sh
./uninstall-cammic.sh
```

The script requests administrator authorization, verifies CamMic's bundle IDs, removes only `/Applications/CamMic.app`, the recognized legacy CamMic app path if present, `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver`, and CamMic's two package receipts. It then restarts `coreaudiod` if the CamMic driver was removed. It does not delete or update BlackHole, ParrotAudioPlugin, other audio drivers, or the recovery backups.

## Build

### Full release build in CI

GitHub Actions uses **macOS 14 and Xcode 15.4 (15F31d)**. It runs the iOS simulator regressions, `swift test` (protocol, renderer, and device-catalog tests), builds the two-channel universal CamMic HAL driver and installers, creates the unsigned iOS IPA, builds `CamMic.app`, and packages the source and macOS installers.

The iOS regression targets cover route changes, bounded capture/conversion, and listener/session isolation. Swift Package tests cover the shared protocol, Mac renderer, and CamMic device catalog, including direct lookup of the hidden output UID, direction-specific scopes, format changes, disappearance, and replacement handles. This Mac has Command Line Tools without XCTest, so test execution is provided by CI; the local Swift Package product build is available here.

The workflow artifact contains:

- `CamMic-iOS14-unsigned.ipa` and `build-report.txt`
- `CamMic.app`, `CamMic-Installer.pkg`, and `CamMicAudioDriver.pkg`
- `CamMic-macOS-arm64-<commit>.zip` and the matching `CamMic-Source-<commit>.tar.gz`
- `mac-build-report.txt`, `audio-driver-build-report.txt`, and `installer-build-report.txt`

### Reproduce with Xcode 15.4

```sh
./scripts/build-audio-driver.sh
./scripts/build-source-bundle.sh
./scripts/build-unsigned-ipa.sh
./scripts/build-mac-app.sh
./scripts/build-installer-package.sh
```

The editable source is `Assets/CamMicIcon.svg`; its generated iOS and Mac resources are checked in. iOS uses the full-bleed opaque artwork so iOS can apply its own corner mask. The Mac icon keeps the same background and graphic but insets the foreground by 6% for the platform's icon mask. After editing the SVG, run `./scripts/generate-icons.sh`, inspect both previews, and commit the changed icon resources before making a release build.

The driver build applies `Driver/patches/blackhole-cammic.patch` to a temporary copy of the pinned upstream source. It does not edit the vendored upstream tree or touch installed audio drivers. `build-source-bundle.sh` packages the committed source revision; build it from a clean commit so that its source snapshot exactly matches the binaries.

This Mac currently has Command Line Tools but no full Xcode. `swift build --product CamMicMac` and the arm64 Mac app build can run locally; the iOS simulator, iOS IPA, HAL driver, and PKG builds run in the Xcode 15.4 workflow. The local app's minimum macOS version is **13.0**.

## Verification procedure

For an actual recording test, use an independent input app such as QuickTime; a device list entry, connected status, or moving meter alone does not prove the microphone path.

1. Install the IPA on the iPhone and the combined Mac installer. Confirm the iPhone remains in the foreground during capture.
2. Start iPhone capture and use the existing Wi-Fi or USB flow. Enter the current iPhone address and pairing code in CamMic Mac.
3. In QuickTime, select **CamMic**, record speech from the phone, save the recording, and play it back. Separately check that Mac system sounds did not enter the recording.
4. Stop, disconnect the phone, and quit CamMic. Confirm QuickTime input becomes silent. Reconnect a new session and verify that the prior recording is not replayed.
5. Confirm the Mac default output remains unchanged and original BlackHole remains installed and usable. Repeat the installer once to check upgrade behavior; uninstall CamMic and confirm other audio devices remain.

The workflow's automated checks do not replace this microphone recording test. Recordings from the earlier R1 build are historical evidence for the existing transport and session handling; they do not verify this new HAL driver.

Earlier R1 validation used the original BlackHole 2ch route. CI run [40176960511](https://github.com/YYKX682436/CamMic/actions/runs/40176960511) passed 20 existing tests. USB QuickTime samples and run notes are retained under `dist/ci-40176960511/`; the short sample confirmed live signal, but its speech content was not independently acoustically reviewed. Those results do not establish that the new CamMic HAL input device works.

## License and source

The integrated CamMic app/driver distribution is under **GPL-3.0**; the full license is in `LICENSE`. CamMic source that predates the GPL integration retains its original MIT notice in `LICENSES/MIT-CamMic-original.txt`. The exact upstream notice is in `LICENSES/BlackHole-v0.7.1.txt` and `Driver/BlackHole-v0.7.1/LICENSE`.

The matching full source is shipped as `CamMic-Source-<commit>.tar.gz` in the Mac archive and is embedded in `CamMic.app/Contents/Resources/`. The standalone driver package and combined Installer also include the exact GitHub source URL and commit in their notices. The archive contains the exact CamMic commit, pristine BlackHole source, the CamMic patch/configuration, and license notices. `Driver/UPSTREAM.md` documents the stable driver identities and build method.
