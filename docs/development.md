# CamMic developer notes

This document contains protocol, CoreAudio, build, test, and packaging details. For ordinary installation and use, see the [Chinese quick guide](安装与使用.md) or the English [project home](../README.md). CamMic currently ships microphone input only; camera support is paused.

The iPhone app keeps its existing local-network transport, USB-default no-code connection, session isolation, bounded PCM queues, and silence-on-underrun behavior. USB uses a temporary TLS-PSK key created for each active capture session. iOS continues to require **14.0 or later**. The existing app Bundle IDs are unchanged.

## Existing audio transport

- `CamMic/AudioCapture.swift` copies microphone PCM into a 12-slot preallocated pool, with a 300 ms in-flight limit. Conversion, metering, framing, and sending run on a worker queue. When a callback would exceed that duration, the capture queue drops the oldest queued input blocks to retain live audio; structurally invalid buffers still end the capture run and clear queued audio.
- The conversion worker drains each accepted input block before reusing its slot and joins samples into complete transport frames. `Shared/CamMicProtocol.swift` uses a versioned, length-limited format with a 16-byte session ID and increasing frame sequence. Audio frames contain 960 samples at 48 kHz, mono, signed PCM16 little-endian (20 ms / 1,920 bytes).
- Advanced Wi-Fi mode listens on TCP port **50888** and uses an ephemeral eight-digit pairing code as a TLS-PSK. USB is the default and uses a fresh random 32-byte key through two additional iPhone loopback-only listeners. The USB key changes on every capture start and is discarded on stop.
- The Mac accepts one phone session and sends cumulative acknowledgements after the CoreAudio callback consumes a packet. The iPhone has at most eight unacknowledged frames and an independent eight-frame pending-send buffer. If the Mac falls behind, the sender drops the oldest unsent audio to keep the stream live; after 1.25 seconds without ACK progress, it closes only that network session, clears its old audio, and keeps microphone capture and the listener running for reconnection. A replacement connection starts a new protocol session and receives only live audio. The Mac output ring is limited to twelve packets and writes silence on underrun. This acknowledgement is not a measurement of physical acoustic output latency.
- The iPhone diagnostics panel refreshes once per second with callback sizes/counts, capture queue high-water and wait time, PCM conversion time, pending network packets/drops, and ACK stall/RTT.
- Both real-time callbacks avoid waiting on shared state. The Mac callback clears output and returns silence if it cannot acquire renderer state; queue contention has a separate counter from ordinary underruns. Stop, overflow, protocol errors, disconnect, reconnect, and app termination clear session audio; app termination waits for the output IOProc to stop before exit.
- Listener and connection callbacks carry generation/session identity so delayed callbacks from an earlier session cannot alter a replacement session. Receive decoders and acknowledgement windows are scoped to their connection.

## Mac audio device architecture

- The CamMic HAL driver is built from the official BlackHole v0.7.1 source at commit [`e2b22aaaba4e507a097131704bf96dabc004d9cf`](https://github.com/ExistentialAudio/BlackHole/tree/e2b22aaaba4e507a097131704bf96dabc004d9cf). Its source, exact patch, fixed build configuration, and license are retained in this repository.
- The public input-only device is `CamMic`, UID `CamMic2ch_UID`. It has two input channels and no output channels.
- The hidden output-only endpoint is `CamMicInternalOutput`, UID `CamMic2ch_2_UID`. The Mac receiver writes mono phone audio into both output channels.
- The model UID is `CamMic2ch_ModelUID`, the HAL bundle ID is `com.yykx682436.CamMicAudioDriver`, the bundle path is `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver`, and the plug-in factory UUID is `4b469f5a-1284-4ac8-b82c-75026d5ae711`. These values stay fixed across upgrades. They are distinct from the original BlackHole identities, so both drivers can coexist; the BlackHole app/driver is not a CamMic runtime dependency.
- `AudioDeviceCatalog.device(uid:)` resolves the hidden endpoint with `kAudioHardwarePropertyTranslateUIDToDevice`; it does not enumerate visible output devices. Output channel layout and stream format are checked with output scope. The public microphone is resolved separately, with channel and stream-format checks in input scope. The receiver repeats both checks while connected and stops, mutes, and clears its ring if either endpoint disappears, is replaced, or changes direction/format.
- The receiver reports transport/TLS, CamMic protocol, and PCM-output failures separately. Its diagnostics include received PCM byte growth and the latest PCM RMS/peak, output queue depth, CoreAudio consumption, underruns, and protocol errors. A nonzero packet count or meter alone is not treated as proof of an audible recording.
- Both endpoints share one nonzero CoreAudio clock domain and list each other as related devices. The public stream and input controls report the public device as owner; the hidden output stream, volume, and mute controls report the hidden output device as owner. The driver callback exposes both device objects; CoreAudio's ordinary device inventory omits the hidden output, which remains resolvable by its plug-in and system UID translation APIs.
- CamMic's HAL patch keeps the pinned upstream files pristine. It replaces the unsynchronized float `memcpy` ring with per-frame atomic publication, exact sample-time matching, and an output-session generation. Input callbacks produce zero for missing, partially written, muted, or prior-session frames. Stopping the last hidden-output client advances the generation and clears the ring; concurrent output writers are reported as a CoreAudio write error rather than mixed unpredictably.
- The app's component status shows whether both CamMic endpoints are ready. It writes to its fixed hidden CamMic output and never asks the user to select BlackHole or an arbitrary output. **Open Microphone Input Settings** opens the macOS input selector; choose CamMic there or in the recording app. If BlackHole is also installed, it may appear as a separate device, but it is optional and is not CamMic's route. If the driver is missing, **Install or Repair Audio Component** opens the driver-only installer bundled inside `CamMic.app`.

## USB session security boundary

USB is the default. The iPhone exposes loopback-only initialization and audio listeners while capture is active. The Mac discovers the USB-connected phone and forwards to these listeners using the in-process libusbmuxd API; it bundles the LGPL runtime libraries. No CamMic pairing code, IP address, terminal command, Homebrew, or `iproxy` is needed. USB does not fall back to Wi-Fi. Multiple phones are selected in the Mac app. Advanced Wi-Fi retains the existing IP and pairing-code flow.

Each iPhone capture creates a temporary 32-byte key, returns it over the USB-forwarded loopback initialization channel, uses it for the existing TLS-PSK audio connection, and discards it when capture stops. CamMic does not authenticate a particular Mac process. Another process with access to the trusted USB forwarding path or the iPhone loopback socket may obtain the temporary key during active capture. USB loopback is not reachable over Wi-Fi. Neither trusted-host testing nor `idevicepair validate` proves that every untrusted host is blocked from custom USBMux ports. The chosen boundary was kept unchanged for this release candidate.

Unplugging or a recoverable transport failure reconnects with a fresh protocol session and current audio only. Mac mute and manual stop clear queued audio; manual stop suppresses reconnect until the user resumes. These behaviors and related lifecycle tests are implemented in `MacApp/USBAutoConnectionController.swift`, `MacApp/MacUSBTransport.swift`, `CamMic/AudioLinkServer.swift`, and `Shared/CamMicProtocol.swift`.

## Installer and recovery behavior

The combined package installs only `/Applications/CamMic.app` and `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver`. PackageKit relocation is disabled, so an existing app with the same Bundle ID cannot redirect the install path. Preinstall backs up the recognized CamMic app and driver; postinstall checks bundle IDs, ad-hoc signatures, driver factory identity, and CoreAudio restart. If postinstall fails, it restores the previous CamMic files. If installation is interrupted before rollback completes, the recovery pointer and backups remain in `/Library/Application Support/CamMic/Recovery/`; the next install validates and restores pending state first. `restore-cammic-install.sh` can perform that restoration directly.

Uninstall checks the CamMic bundle IDs before removing the two known CamMic app paths, the CamMic HAL bundle, and CamMic package receipts. It does not remove BlackHole, ParrotAudioPlugin, or other audio drivers, and it retains recovery backups. The release ZIP puts the full installer at its top level and places the standalone driver repair package and uninstall/recovery utilities under `optional-tools/`.

The Mac app and HAL driver have local ad-hoc signatures; the installer package and iOS IPA are unsigned. None is Developer ID signed or notarized. User instructions allow only CamMic-specific first-open approval and do not require disabling system-wide security.

## Build

### Full release build in CI

GitHub Actions uses **macOS 14 and Xcode 15.4 (15F31d)**. It runs iOS simulator regressions and Swift Package tests; builds the pinned LGPL USBMux libraries for macOS 13; builds the universal CamMic HAL driver; creates the unsigned iOS IPA, Mac app, combined installer, and exact source archive; runs real CoreAudio PCM loopback; and performs a 0.5.0-to-0.6.0 package upgrade, a failed-upgrade recovery, repeat install, and CamMic-only uninstall against the unrelated CoreAudio inventory and defaults.

The iOS regression targets cover route changes, bounded capture/conversion, and listener/session isolation. The capture/network regressions include repeated 44.1 kHz 4410-frame callbacks, the 300 ms capture bound, delayed or missing ACKs, bounded stale-frame drops, recovery without sequence gaps, and reconnect isolation. Swift Package tests cover the shared protocol, Mac renderer, device catalog, USB discovery coordination, retries and manual-stop precedence, stale callbacks, and in-process forwarding port cleanup. The LGPL runtime libraries are built from pinned source archives and bundled in CamMic.app. This Mac has Command Line Tools without XCTest, so test execution is provided by CI; the local Swift Package product build is available here.

The public workflow artifact exposes only `CamMic-iOS14-unsigned.ipa`, `CamMic-macOS-arm64.zip`, and `SHA256SUMS`. GitHub Actions logs record each build and test result; build reports, the CoreAudio PCM test, and lifecycle summaries are printed in the job output. Detailed inventory snapshots are temporary runner files and are not distributed. The Mac ZIP has one main installer, matching complete source, notices, and an `optional-tools/` directory for standalone driver repair and uninstall/recovery scripts. `SHA256SUMS` checks the two downloadable artifacts; the ZIP contains a build manifest for its source and optional tools.

The lifecycle check validates the pinned 0.5.0 fixture (`TestFixtures/CamMic-Installer-0.5.0-06d0737.pkg`) before installation, confirms its actual app bundle ID/version/build, then verifies the 0.6.0 app executable and all three bundled USBMux libraries after upgrade. It snapshots device UIDs, channel counts, hidden/running flags, default eligibility, transport, owners, plug-ins, and default selections. If BlackHole is installed, its files are hash-checked throughout. One failure case corrupts the candidate app's code signature in a throwaway package and confirms installation restores 0.5.0. A second simulates interruption immediately after preinstall backs up the old bundles and removes their install paths, then runs the recovery command and verifies 0.5.0 is restored and the transaction pointer is cleared.

### Reproduce with Xcode 15.4

For dependency builds, install the build-time Autotools and pkg-config packages. They are not runtime requirements for CamMic users:

```sh
brew install autoconf automake libtool pkgconf
```

```sh
./scripts/build-audio-driver.sh
./scripts/build-source-bundle.sh
./scripts/build-unsigned-ipa.sh
./scripts/build-usbmuxd-dependencies.sh
./scripts/build-mac-app.sh
./scripts/build-installer-package.sh
./scripts/build-release-candidate.sh
```

The editable source is `Assets/CamMicIcon.svg`; generated iOS and Mac resources are checked in. iOS uses an opaque, full-bleed image and lets iOS apply its corner mask. The Mac ICNS uses the same mic artwork on an inset blue rounded rectangle with transparent corners and a soft shadow. `scripts/generate-icons.sh` validates the iOS alpha and every Mac ICNS representation, including 16 px Dock size and larger Finder sizes. Both the app and driver build scripts byte-compare the packaged ICNS with `Assets/CamMic.icns`. The app's `NSApp.applicationIconImage` runtime override reads this same resource. After editing the SVG, run `./scripts/generate-icons.sh` and review both generated masters.

The driver build applies `Driver/patches/blackhole-cammic.patch` to a temporary copy of the pinned upstream source. It does not edit the vendored upstream tree or touch installed audio drivers. `scripts/test-cammic-coreaudio-driver.sh install` installs the resulting CamMic-only package on the CI runner and sends known 997 Hz and 1499 Hz PCM into the translated hidden output UID. It records actual samples captured from public CamMic, verifies amplitude, continuity, stereo duplication, stream/control owners, hidden visibility, related devices and shared clock domain, then checks silence after stop and that a restarted stream contains only the new signal. It also verifies the default input and outputs did not change. Run `scripts/test-cammic-coreaudio-driver.sh installed` after installing the package on a Mac. `build-source-bundle.sh` packages the committed source revision; build it from a clean commit so that its source snapshot exactly matches the binaries.

The build host used for the physical test has Command Line Tools but no full Xcode, so simulator, IPA, HAL driver, and installer builds run in Xcode 15.4 CI. The release candidate is iOS **0.6.0 (4)**, minimum iOS **14.0**, and Mac **0.6.0 (6)**, minimum macOS **13.0** on arm64. These minimums are not a device-coverage claim.

## Verification procedure

For an actual recording test, use an independent input app such as QuickTime; a device list entry, connected status, or moving meter alone does not prove the microphone path.

1. Install the IPA on the iPhone and the combined Mac installer. Start capture on iPhone, then lock the screen or switch apps; iOS background audio mode keeps the active recording session running while ordinary screen sleep remains enabled. Calls, Siri, and competing audio sessions can still interrupt recording.
2. Connect the cable. CamMic Mac should discover and connect automatically; Wi-Fi remains in Advanced Options. Closing the main window leaves the app session and menu bar controls active.
3. In QuickTime, select **CamMic**, record speech from the phone, save the recording, and play it back. Separately check that Mac system sounds did not enter the recording.
4. Stop, disconnect the phone, and quit CamMic. Confirm QuickTime input becomes silent. Reconnect a new session and verify that the prior recording is not replayed.
5. Confirm the Mac default output and the unrelated CoreAudio inventory remain unchanged. If original BlackHole is installed, confirm it remains intact. CI repeats the installer and tests safe CamMic-only removal after upgrading from the 0.5.0 fixture.

The workflow's synthetic PCM test proves the local HAL route and sample values on its runner; it does not replace a recording of actual iPhone speech. For the physical phone check, verify automatic USB discovery, TLS-ready state, CamMic hello/ready, received PCM byte growth and nonzero PCM RMS/peak, consumed output sequence, and a saved QuickTime recording with CamMic selected. Report system default input separately from the chosen QuickTime input. The app writes only to CamMicInternalOutput and does not change the Mac default output.

`scripts/cammic-coreaudio-inspect.c` records names, UIDs, direction channel counts, hidden and running flags, stream/control ownership, default-device choices, and direct UID translation for both CamMic endpoints. Run it before and after installation or upgrade when checking the local device inventory. The PCM integration test captures 997 Hz then 1499 Hz, rejects measurable leakage from the prior session, checks stereo identity and adjacent-sample continuity, and verifies silence after each stop.

The prior XR/iOS 14.3 USB feasibility record is retained at [`docs/validation/USB-XR-iOS14.3-2026-10-26.md`](validation/USB-XR-iOS14.3-2026-10-26.md). It concerns a stage ②-1 manually forwarded build and must not be used to claim that this candidate passed automatic USB discovery or real QuickTime recording. The candidate-specific test record is [`docs/releases/0.6.0-beta1.md`](releases/0.6.0-beta1.md).

## License and source

The integrated CamMic app/driver distribution is under **GPL-3.0**; the full license is in `LICENSE`. CamMic source that predates the GPL integration retains its original MIT notice in `LICENSES/MIT-CamMic-original.txt`. The exact upstream notice is in `LICENSES/BlackHole-v0.7.1.txt` and `Driver/BlackHole-v0.7.1/LICENSE`.

The matching full source is shipped as `CamMic-Source-<commit>.tar.gz` in the Mac archive and embedded in `CamMic.app/Contents/Resources/`. The standalone driver package and combined Installer include the exact GitHub source URL and commit in their notices. The source archive contains the exact CamMic commit, pristine BlackHole source, the CamMic patch/configuration, and license notices. `Driver/UPSTREAM.md` documents the stable driver identities and build method.

CamMic.app dynamically links the bundled LGPL-2.1-or-later USBMux libraries. Their pinned source archives and license texts are shipped beside the app. The libusbmuxd archive also contains source files for its separately licensed GPL-2.0-or-later utilities; those tools are not built into or distributed as executables with CamMic.
