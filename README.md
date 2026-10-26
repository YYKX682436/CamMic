# CamMic

CamMic sends live iPhone microphone audio to a Mac. The Mac publishes one dedicated system input device named **CamMic**. Other Mac apps, including QuickTime Player, can select CamMic as their microphone. The CamMic Mac app writes to a hidden, output-only endpoint; it does not change the Mac's default input, default speakers, or route system audio into the microphone. The default input selection and the existence/name of the CamMic input are separate; select **CamMic** in a recording app when it is not already selected.

The iPhone app keeps its existing local-network and USB transport, TLS-PSK pairing, session isolation, bounded PCM queues, and silence-on-underrun behavior. iOS continues to require **14.0 or later**. The existing app Bundle IDs are unchanged.

## Existing audio transport

- `CamMic/AudioCapture.swift` copies microphone PCM into a 12-slot preallocated pool, with a 300 ms in-flight limit. Conversion, metering, framing, and sending run on a worker queue. When a callback would exceed that duration, the capture queue drops the oldest queued input blocks to retain live audio; structurally invalid buffers still end the capture run and clear queued audio.
- The conversion worker drains each accepted input block before reusing its slot and joins samples into complete transport frames. `Shared/CamMicProtocol.swift` uses a versioned, length-limited format with a 16-byte session ID and increasing frame sequence. Audio frames contain 960 samples at 48 kHz, mono, signed PCM16 little-endian (20 ms / 1,920 bytes).
- The iPhone listens on TCP port **50888**. The Mac connects to it over Network.framework using an ephemeral eight-digit pairing code as a TLS-PSK. The code changes when capture starts; both sides pin TLS 1.2 for Network.framework's PSK support. Use the pairing code only on a trusted local connection while CamMic is actively capturing.
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

## Install on macOS

Download the `CamMic-Step1-<commit>` artifact from the successful GitHub Actions run for the desired commit. The `CamMic-macOS-arm64-<commit>.zip` contains the named app, the combined installer, the standalone driver installer, source, notices, and uninstall/recovery scripts. The Actions artifact also contains the unsigned iOS IPA and build reports.

1. Unzip the Mac archive and quit CamMic and any app currently recording audio.
2. Open `CamMic-Installer.pkg` and follow the macOS administrator prompts. The package installs `/Applications/CamMic.app` and only `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver` for the driver. It terminates the running `coreaudiod` process, lets launchd start it again, and waits for a new process ID; audio apps may briefly lose their audio route during this step. If the service does not return, installation restores the previous CamMic files and leaves recovery data in place.
3. Open **CamMic**. Its status should report `系统麦克风：CamMic` and that the internal output is ready.
4. In CamMic, click **打开麦克风输入设置**. In **System Settings → Sound → Input**, select **CamMic**. This changes only the input choice; leave the **Output** tab on your normal speakers.
5. In QuickTime Player, choose **File → New Audio Recording**, open the input menu, and select **CamMic**. QuickTime may request microphone permission. Apps with their own input menu must select CamMic there too; the CamMic Mac app itself has no microphone-source dropdown because CamMic is the input device it publishes.

The installer disables PackageKit bundle relocation so the app stays at `/Applications/CamMic.app` even when an earlier CamMic build with the same Bundle ID is still at its old path. It backs up an existing CamMic app and driver before replacement and validates the installed bundle identities. A failed install restores the previous files when the installer can run its recovery step. If installation stops after changing files, the recovery copy and state remain under `/Library/Application Support/CamMic/Recovery/`; the next combined install validates and restores that pending CamMic state before beginning a fresh transaction. To restore without reinstalling, run `restore-cammic-install.sh` from the archive. Recovery backups are retained. A successful upgrade removes the previous app at `/Applications/CamMic-Mac-arm64.app` only when that bundle has CamMic's former bundle ID.

The installer, app, and driver are not Developer ID signed or notarized. The Mac app and HAL driver have local ad-hoc code signatures; the package is unsigned. macOS may require the user to confirm opening the downloaded installer. No Apple signing credentials or notarization credentials are included.

## Install the iPhone app

`CamMic-iOS14-unsigned.ipa` is arm64 and unsigned. Install it with the existing 全能签 flow and its existing provisioning setup. The app Bundle ID remains `com.yykx682436.CamMic`. Allow microphone and local-network access when asked. The workflow does not use signing secrets.

For the USB feasibility probe only, use `CamMic-USBProbe-Debug-iOS14-unsigned.ipa` and `CamMic-USBProbe-Debug-macOS-arm64.zip` from the same successful Actions run. The iPhone IPA needs the existing signing flow. It shares the normal iPhone Bundle ID so installing it replaces the app binary while preserving app data; the separate Debug Mac app uses a distinct Bundle ID. These artifacts contain test-only USB listeners and are not release packages.

## Connect over USB

The existing manual USB path can still forward the Wi-Fi-era TLS listener on port `50888`. The no-code feasibility probe is a separate **Debug-only** path and is not compiled into the Release iPhone or Mac apps. It uses the same TLS-PSK and CamMic audio protocol, but adds two USBMux forwarded ports: initialization `50889` and TLS audio `50890`. Both iPhone listeners require `127.0.0.1`; Wi-Fi clients must use neither port. Automatic device discovery and production USB connection management remain out of scope.

For the Debug probe, install the official Homebrew `libusbmuxd` and `libimobiledevice` packages if needed, connect and unlock the iPhone, trust the Mac if iOS asks, and get the XR UDID from Finder's device details. Build and install Debug versions of both apps using the existing signing setup. Run:

```sh
./scripts/run-iproxy-usb.sh <XR-UDID>
```

The proxy explicitly binds its Mac-side ports to `127.0.0.1` and forwards `50888`, `50889`, and `50890` over USBMux. On iPhone, tap **Debug：启动 USB 回环探针** to start capture; only after microphone startup succeeds does the initialization listener start. Then click **Debug：USB 免码探针** in the Debug Mac app. The receiver requests the current 32-byte random session key from `127.0.0.1:50889`, connects to `127.0.0.1:50890` with TLS-PSK, and uses the existing HELLO / READY, PCM16, ACK, and CamMic HAL output path. It never accepts an IP or falls back to Wi-Fi. Stop capture to cancel both listeners and invalidate the session key; the next start generates a new key. The init channel permits at most eight requests per capture run.

For Wi-Fi isolation, keep capture active and Wi-Fi enabled, then from the Mac try `nc -vz -w 2 <iPhone-LAN-IP> 50889` and `nc -vz -w 2 <iPhone-LAN-IP> 50890`. Both must fail while the USB loopback path succeeds. Record those results, the TLS and HELLO / READY statuses, rising nonzero PCM RMS/peak and byte counts, a QuickTime recording with CamMic selected, and the unchanged default input/output inventory. A proxy process or open port alone does not prove an audio path.

Security boundary: this run used an already trusted/paired Mac. The provided script validates existing pairing with `idevicepair validate`, then pins the requested UDID and USB transport; it never creates pairing records or changes system trust. USBMux/iproxy is a port transport, and this test does not prove a universal system-trust ACL on custom app ports. Untrusted-host rejection remains `NOT_VERIFIED`. The iPhone app only sees a connection to its loopback socket and cannot prove which Mac process or host originated it. The Debug init response carries the key without application-level encryption or Mac public-key authentication. Loopback prevents Wi-Fi access; it does not prevent another process with loopback/forwarding access from requesting the key. Strict app identity requires a first-use user approval that pins a Mac public key, then signed challenge-response and encryption of each fresh session key to that pinned key. That trust UI and key storage are not part of this probe, so the no-code path is not ready to become a production interface.

The proxy requires modern `iproxy` with explicit `--local` and `--source` controls; unverified older syntax is rejected. With the Mac app disconnected, the client-only `./scripts/run-usb-handshake-validation.sh --lifecycle` checks current/wrong/old keys, PSK identity, HELLO / READY, nonzero PCM, concurrent-session policy, and operator-confirmed capture stop/restart. It retains key material only in memory and never prints it. The Actions artifact also includes a precompiled `cammic-usb-handshake-validation` executable.

XR / iOS 14.3 USB loopback, no-code TLS/audio, Wi-Fi isolation, physical unplug silence, and a Wi-Fi regression were verified on 2026-10-26. See the [probe guide](docs/USB-probe-validation.md) and [physical XR record](docs/validation/USB-XR-iOS14.3-2026-10-26.md) for evidence and remaining identity limits.

## Uninstall CamMic

Run `uninstall-cammic.sh` from the downloaded Mac archive or this repository:

```sh
./uninstall-cammic.sh
```

The script requests administrator authorization, verifies CamMic's bundle IDs, removes only `/Applications/CamMic.app`, the recognized legacy CamMic app path if present, `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver`, and CamMic's two package receipts. It then restarts `coreaudiod` if the CamMic driver was removed. It does not delete or update BlackHole, ParrotAudioPlugin, other audio drivers, or the recovery backups.

## Build

### Full release build in CI

GitHub Actions uses **macOS 14 and Xcode 15.4 (15F31d)**. It runs the iOS simulator regressions, `swift test` (protocol, renderer, and device-catalog tests), builds the two-channel universal CamMic HAL driver and installers, installs the driver on the runner and records real CoreAudio PCM samples, creates the unsigned iOS IPA, builds `CamMic.app`, packages the source and macOS installers, then repeats the combined install and checks CamMic-only uninstall against the unrelated CoreAudio inventory and defaults.

The iOS regression targets cover route changes, bounded capture/conversion, and listener/session isolation. The capture/network regressions include repeated 44.1 kHz 4410-frame callbacks, the 300 ms capture bound, delayed or missing ACKs, bounded stale-frame drops, recovery without sequence gaps, and reconnect isolation. Swift Package tests cover the shared protocol, Mac renderer, and CamMic device catalog, including direct lookup of the hidden output UID, direction-specific scopes, format changes, disappearance, and replacement handles. This Mac has Command Line Tools without XCTest, so test execution is provided by CI; the local Swift Package product build is available here.

The workflow artifact contains:

- `CamMic-iOS14-unsigned.ipa` and `build-report.txt`
- `CamMic-USBProbe-Debug-iOS14-unsigned.ipa` and `CamMic-USBProbe-Debug-macOS-arm64.zip` for the explicitly test-only USB probe
- `CamMic.app`, `CamMic-Installer.pkg`, and `CamMicAudioDriver.pkg`
- `CamMic-macOS-arm64-<commit>.zip` and the matching `CamMic-Source-<commit>.tar.gz`
- `mac-build-report.txt`, `audio-driver-build-report.txt`, and `installer-build-report.txt`
- CoreAudio endpoint inventories, a captured known-signal WAV, and the integration-test report under `cammic-coreaudio-validation/`
- before/after device and plug-in inventories for a real 0.3.1-to-0.3.2 package upgrade, repeat 0.3.2 install, and CamMic-only uninstall under `cammic-install-lifecycle-validation/`; the inventory parser rejects empty baselines and compares names, UIDs, channel counts, hidden/running flags, default eligibility, transport, ownership class, plug-ins, and default selections. If BlackHole is installed, its bundle is separately hash-checked to prove CamMic's lifecycle phases left it untouched.

### Reproduce with Xcode 15.4

```sh
./scripts/build-audio-driver.sh
./scripts/build-source-bundle.sh
./scripts/build-unsigned-ipa.sh
./scripts/build-mac-app.sh
./scripts/build-installer-package.sh
```

The editable source is `Assets/CamMicIcon.svg`; generated iOS and Mac resources are checked in. iOS uses an opaque, full-bleed image and lets iOS apply its corner mask. The Mac ICNS uses the same mic artwork on an inset blue rounded rectangle with transparent corners and a soft shadow. `scripts/generate-icons.sh` validates the iOS alpha and every Mac ICNS representation, including 16 px Dock size and larger Finder sizes. Both the app and driver build scripts byte-compare the packaged ICNS with `Assets/CamMic.icns`. The app's `NSApp.applicationIconImage` runtime override reads this same resource. After editing the SVG, run `./scripts/generate-icons.sh` and review both generated masters.

The driver build applies `Driver/patches/blackhole-cammic.patch` to a temporary copy of the pinned upstream source. It does not edit the vendored upstream tree or touch installed audio drivers. `scripts/test-cammic-coreaudio-driver.sh install` installs the resulting CamMic-only package on the CI runner and sends known 997 Hz and 1499 Hz PCM into the translated hidden output UID. It records actual samples captured from public CamMic, verifies amplitude, continuity, stereo duplication, stream/control owners, hidden visibility, related devices and shared clock domain, then checks silence after stop and that a restarted stream contains only the new signal. It also verifies the default input and outputs did not change. Run `scripts/test-cammic-coreaudio-driver.sh installed` after installing the package on a Mac. `build-source-bundle.sh` packages the committed source revision; build it from a clean commit so that its source snapshot exactly matches the binaries.

This Mac currently has Command Line Tools but no full Xcode. `swift build --product CamMicMac` and the arm64 Mac app build can run locally; the iOS simulator, iOS IPA, HAL driver, and PKG builds run in the Xcode 15.4 workflow. The local app's minimum macOS version is **13.0**.

## Verification procedure

For an actual recording test, use an independent input app such as QuickTime; a device list entry, connected status, or moving meter alone does not prove the microphone path.

1. Install the IPA on the iPhone and the combined Mac installer. Confirm the iPhone remains in the foreground during capture.
2. Start iPhone capture and use the existing Wi-Fi or USB flow. Enter the current iPhone address and pairing code in CamMic Mac.
3. In QuickTime, select **CamMic**, record speech from the phone, save the recording, and play it back. Separately check that Mac system sounds did not enter the recording.
4. Stop, disconnect the phone, and quit CamMic. Confirm QuickTime input becomes silent. Reconnect a new session and verify that the prior recording is not replayed.
5. Confirm the Mac default output remains unchanged. If original BlackHole is installed, confirm it remains intact through CamMic install/update/uninstall; its presence is optional. Repeat the installer once to check repeat-install behavior; the CI test separately upgrades a real 0.3.1 installation to 0.3.2 and uninstalls CamMic while checking all unrelated devices.

The workflow's synthetic PCM test proves the local HAL route and sample values on its runner; it does not replace a recording of actual iPhone speech. For the phone check, confirm the USBMux device identity and local proxy, then verify TLS-ready state, CamMic hello/ready, received PCM byte growth and nonzero PCM RMS/peak, consumed output sequence, and a saved QuickTime recording with CamMic selected. Report system default input separately from the chosen QuickTime input. The app writes only to CamMicInternalOutput and does not change the Mac default output.

`scripts/cammic-coreaudio-inspect.c` records names, UIDs, direction channel counts, hidden and running flags, stream/control ownership, default-device choices, and direct UID translation for both CamMic endpoints. Run it before and after installation or upgrade when checking the local device inventory. The PCM integration test captures 997 Hz then 1499 Hz, rejects measurable leakage from the prior session, checks stereo identity and adjacent-sample continuity, and verifies silence after each stop.

Earlier R1 validation used the original BlackHole 2ch route. CI run [40176960511](https://github.com/YYKX682436/CamMic/actions/runs/40176960511) passed 20 existing tests. USB QuickTime samples and run notes are retained under `dist/ci-40176960511/`; the short sample confirmed live signal, but its speech content was not independently acoustically reviewed. Those results do not establish that the new CamMic HAL input device works.

## License and source

The integrated CamMic app/driver distribution is under **GPL-3.0**; the full license is in `LICENSE`. CamMic source that predates the GPL integration retains its original MIT notice in `LICENSES/MIT-CamMic-original.txt`. The exact upstream notice is in `LICENSES/BlackHole-v0.7.1.txt` and `Driver/BlackHole-v0.7.1/LICENSE`.

The matching full source is shipped as `CamMic-Source-<commit>.tar.gz` in the Mac archive and is embedded in `CamMic.app/Contents/Resources/`. The standalone driver package and combined Installer also include the exact GitHub source URL and commit in their notices. The archive contains the exact CamMic commit, pristine BlackHole source, the CamMic patch/configuration, and license notices. `Driver/UPSTREAM.md` documents the stable driver identities and build method.
