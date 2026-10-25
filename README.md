# CamMic

CamMic aims to use an older iPhone as a Mac microphone and camera. Phase ①-1 is a small, foreground-only iPhone microphone check. It has no network connection, camera access, USB transport, or Mac audio driver.

## Phase ①-1 app

The native UIKit app targets **iOS 14.0** and uses `AVAudioEngine` to capture the microphone's actual input format. It shows microphone permission, a live level from PCM samples, and records up to 12 seconds to a local CAF file for playback after capture stops. Leaving the foreground stops capture and releases the audio session. No account, iCloud, SIM card, or Apple ID match is used at runtime.

The capture implementation is separate from the screen in `CamMic/AudioCapture.swift`. It reports the input sample rate and channel count returned by the device, and exposes a PCM buffer callback for later transport work. This phase does not transmit audio.

## Build an IPA for resigning

The pinned build toolchain is **Xcode 15.4 (15F31d), iOS 17.5 SDK, macOS 14**. Apple's [Xcode support table](https://developer.apple.com/xcode/system-requirements/) lists iOS 14 within its deployment range. GitHub's `macos-14` runner currently includes this version at `/Applications/Xcode_15.4.app`. The workflow checks the version before building; it fails rather than silently switching to a newer Xcode.

On a Mac with that toolchain, run:

```sh
DEVELOPER_DIR=/Applications/Xcode_15.4.app/Contents/Developer ./scripts/build-unsigned-ipa.sh
```

The script creates `dist/CamMic-iOS14-unsigned.ipa`. It verifies the app's `MinimumOSVersion`, arm64 executable, and embedded frameworks. The IPA is **unsigned**: it is intended for signing inside 全能签 with your existing signing setup. It cannot be installed as-is. The GitHub Actions workflow runs the same script and uploads the IPA as a workflow artifact. It does not use signing keys or secrets.

The current Apple Silicon Mac runs macOS 27.0.1 with Command Line Tools only. It has no full Xcode or iOS SDK, so the local build command cannot run here. Xcode 27 targets iOS 15 or later and only supports on-device debugging on iOS 17 or later. Xcode 15.4 is supported on macOS 14, not macOS 27. The macOS 14 runner lets us build for iOS 14 without changing the Mac or iPhone system versions. Building, installing, and debugging an iOS 14.3 device are separate capabilities.

## Install and verify on iPhone XR / iOS 14.3

1. Transfer `CamMic-iOS14-unsigned.ipa` to the iPhone and import it into 全能签.
2. Use your existing certificate and provisioning profile to sign and install it. Keep the app's bundle ID `com.yykx682436.CamMic` unless your profile requires a replacement. Trust the signing profile if iOS asks.
3. Open CamMic, tap **开始采集**, and allow microphone access. Speak near the phone. The level bar and dB value should respond to your voice.
4. Tap **停止采集** (or wait for the 12-second cap), then tap **回放录音**. Confirm your actual speech is clear.
5. Repeat start/stop. While capturing, send the app to the background: capture should stop. Return and start again. Confirm the microphone indicator turns off after stopping.

If permission was denied, enable it in iOS Settings for CamMic and retry. If signing or installation fails, record the exact message, iOS version, signing type, and whether the app opens; do not upgrade or restore the phone as a workaround.

## Verification status (2026-10-25)

- **Build:** Passed on a GitHub Actions macOS 14 runner with Xcode 15.4. The unsigned IPA contains an arm64 executable with Mach-O `minos 14.0`, `MinimumOSVersion 14.0`, the microphone usage string, and no embedded frameworks. The final main commit's Actions run and SHA are reported with the delivery.
- **Installation on iPhone XR / iOS 14.3:** `NOT_VERIFIED`. No iPhone is connected to this Mac, and the IPA still needs signing in 全能签.
- **Microphone capture and playback on iPhone XR / iOS 14.3:** `NOT_VERIFIED`. The manual checks above require the actual phone, permission prompt, voice, and playback.

No device/OS combination has been verified yet. A successful build, IPA creation, or simulator run does not establish iOS 14.3 device behavior.
