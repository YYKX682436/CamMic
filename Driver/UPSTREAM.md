# CamMic audio driver provenance

The HAL engine is based on the official [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 release, pinned to commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`. The full unmodified upstream source and its license are stored in `Driver/BlackHole-v0.7.1/`.

`patches/blackhole-cammic.patch` is the complete source patch. It changes the icon resource reference, assigns a stable, CamMic-specific CoreAudio plug-in factory UUID, removes upstream branding from runtime resources, and returns the two literal CamMic endpoint names without applying BlackHole's channel-count name formatter. `CamMicDriverConfig.h` supplies the public `CamMic` input-only microphone, the hidden output-only `CamMicInternalOutput`, separate stable UIDs, a stable model UID, the CamMic bundle ID and manufacturer, and prevents either endpoint from becoming a default output device. The BlackHole render/capture ring, timing, format, and HAL callbacks remain upstream code.

Stable identities used by the Mac app:

| Identity | Value |
| --- | --- |
| HAL bundle path | `/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver` |
| HAL bundle ID | `com.yykx682436.CamMicAudioDriver` |
| Plug-in factory UUID | `4b469f5a-1284-4ac8-b82c-75026d5ae711` |
| Public input name / UID | `CamMic` / `CamMic2ch_UID` |
| Hidden output name / UID | `CamMicInternalOutput` / `CamMic2ch_2_UID` |
| Model UID | `CamMic2ch_ModelUID` |

## Build

Run `./scripts/build-audio-driver.sh` with Xcode installed. The script first checks that driver direction and device-name settings agree with the Mac app, applies the patch to a temporary copy of the pinned source, copies in the generated CamMic icon (which uses the Mac-specific foreground inset from the same SVG master), builds the upstream `BlackHole` target with `CamMicAudioDriver.xcconfig`, validates all bundle identities, and creates the signed-for-local-use (ad-hoc) driver bundle and installer package. It also embeds the matching complete-source URL and commit in the driver bundle. It does not modify or replace any BlackHole installation.

The project CI build uses Xcode 15.4 on macOS 14. The driver package is not Developer ID signed or notarized. The complete corresponding source is included in the CamMic distribution archive and in `CamMic.app/Contents/Resources/CamMic-Source.tar.gz`.

## License and branding

The upstream source is GPL-3.0. CamMic's integrated macOS application and driver distribution is GPL-3.0; the pre-existing CamMic code retains its original MIT license notice in `LICENSES/MIT-CamMic-original.txt`. The exact upstream license and attribution are retained in `LICENSES/BlackHole-v0.7.1.txt` and the vendored source. The modified driver and its installers use CamMic branding and do not redistribute upstream artwork or product branding.
