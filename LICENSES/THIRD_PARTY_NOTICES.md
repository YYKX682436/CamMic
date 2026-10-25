# Third-party notices

## BlackHole audio engine

CamMic's macOS audio driver uses the HAL driver engine from Existential Audio's BlackHole v0.7.1, commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`.

- Upstream source: <https://github.com/ExistentialAudio/BlackHole/tree/e2b22aaaba4e507a097131704bf96dabc004d9cf>
- License: GNU General Public License version 3.0; see `BlackHole-v0.7.1.txt` and `Driver/BlackHole-v0.7.1/LICENSE`.
- The full pristine upstream source, CamMic configuration header, and exact patch are included in the source archive shipped with CamMic.
- The custom driver is branded CamMic and has a distinct bundle path, bundle identifier, CoreAudio device UIDs, model UID, and plug-in factory UUID. It does not replace or remove BlackHole.

## CamMic original source

The CamMic source that pre-dates the GPL-integrated driver work retains the MIT license grant and copyright notice in `MIT-CamMic-original.txt`. The combined macOS application and driver distribution is provided under GPL-3.0; see the root `LICENSE`.

## Corresponding source

The distribution archive contains `CamMic-Source-<commit>.tar.gz`, a source snapshot corresponding to the built binaries. It contains the CamMic source, exact BlackHole upstream commit, CamMic patch, build configuration, and license files. The same archive is bundled in `CamMic.app/Contents/Resources/`. For a specific build, the driver resource `CamMic-SOURCE.txt` and its build report identify the exact public GitHub source commit and direct archive URL.
