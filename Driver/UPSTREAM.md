# CamMic audio driver provenance

The HAL engine is based on the official [ExistentialAudio/BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.1 release, pinned to commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`. The full unmodified upstream source and its license are stored in `Driver/BlackHole-v0.7.1/`.

`patches/blackhole-cammic.patch` is the complete source patch. It changes the icon resource reference, assigns a stable CamMic-specific CoreAudio plug-in factory UUID, removes upstream branding from runtime resources, and returns the literal CamMic endpoint names without applying BlackHole's channel-count name formatter. It also repairs the plug-in's owned-object list, reports the output stream and output controls as owned by `Device2`, enumerates the output control list from the output object's own table, and gives the two endpoints one shared clock domain and reciprocal related-device lists.

The patch replaces the upstream unsynchronized cross-callback float ring with a fixed-size per-frame atomic ring. Writers publish samples with sequence and generation markers; input callbacks accept only a complete frame at the matching CoreAudio sample time from the current output session. Missing or stale frames are silence. The last output stop advances the generation and clears the slots, so an old frame cannot become audible after reconnect. Concurrent output writers are explicitly rejected by the driver callback rather than racing over shared memory. The pinned upstream `BlackHole.c` is not edited; the reproducible delta is only this patch.

`CamMicDriverConfig.h` supplies the public `CamMic` input-only microphone, the hidden output-only `CamMicInternalOutput`, separate stable UIDs, a stable model UID, and the CamMic bundle ID and manufacturer. The public input is eligible as the default content input so macOS Sound settings and recording apps can select it. The hidden output is ineligible and hidden; neither endpoint is eligible as the system-sounds device.

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

Run `./scripts/build-audio-driver.sh` with Xcode installed. The script checks the endpoint identity and directions, applies the patch to a temporary copy of the pinned source, copies the generated alpha-preserving CamMic ICNS into the driver resources, builds the upstream `BlackHole` target with `CamMicAudioDriver.xcconfig`, validates bundle identities, and creates the local ad-hoc-signed driver bundle and installer package. It embeds the complete-source URL and commit. Then run `./scripts/test-cammic-coreaudio-driver.sh installed` to exercise real CoreAudio output/input sample buffers and stop/restart behavior. It does not modify or replace a BlackHole installation.

The project CI build uses Xcode 15.4 on macOS 14. The driver package is not Developer ID signed or notarized. The complete corresponding source is included in the CamMic distribution archive and in `CamMic.app/Contents/Resources/CamMic-Source.tar.gz`.

## License and branding

The upstream source is GPL-3.0. CamMic's integrated macOS application and driver distribution is GPL-3.0; the pre-existing CamMic code retains its original MIT license notice in `LICENSES/MIT-CamMic-original.txt`. The exact upstream license and attribution are retained in `LICENSES/BlackHole-v0.7.1.txt` and the vendored source. The modified driver and its installers use CamMic branding and do not redistribute upstream artwork or product branding.
