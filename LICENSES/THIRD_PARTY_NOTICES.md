# Third-party notices

## BlackHole audio engine

CamMic's macOS audio driver uses the HAL driver engine from Existential Audio's BlackHole v0.7.1, commit `e2b22aaaba4e507a097131704bf96dabc004d9cf`.

- Upstream source: <https://github.com/ExistentialAudio/BlackHole/tree/e2b22aaaba4e507a097131704bf96dabc004d9cf>
- License: GNU General Public License version 3.0; see `BlackHole-v0.7.1.txt` and `Driver/BlackHole-v0.7.1/LICENSE`.
- The full pristine upstream source, CamMic configuration header, and exact patch are included in the source archive shipped with CamMic.
- The custom driver is branded CamMic and has a distinct bundle path, bundle identifier, CoreAudio device UIDs, model UID, and plug-in factory UUID. It does not replace or remove BlackHole.

## CamMic original source

The CamMic source that pre-dates the GPL-integrated driver work retains the MIT license grant and copyright notice in `MIT-CamMic-original.txt`. The combined macOS application and driver distribution is provided under GPL-3.0; see the root `LICENSE`.

## USB device transport

The Mac app links the following LGPL libraries to discover USB-connected iPhones and open the two device-side loopback channels. Their dynamic libraries are bundled in `CamMic.app/Contents/Frameworks`; users do not need Homebrew, `iproxy`, or `idevice_id` installed.

| Component | Version | License | Upstream | Corresponding source |
| --- | --- | --- | --- | --- |
| libusbmuxd library | 2.1.1 | LGPL-2.1-or-later | https://github.com/libimobiledevice/libusbmuxd | `Vendor/SourceArchives/libusbmuxd-2.1.1.tar.gz` |
| libimobiledevice-glue | 1.3.3 | LGPL-2.1-or-later | https://github.com/libimobiledevice/libimobiledevice-glue | `Vendor/SourceArchives/libimobiledevice-glue-1.3.3.tar.gz` |
| libplist | 2.8.0 | LGPL-2.1-or-later | https://github.com/libimobiledevice/libplist | `Vendor/SourceArchives/libplist-2.8.0.tar.gz` |

The matching upstream `COPYING`/`COPYING.LESSER` files are included in each source archive and copied beside the libraries in the app bundle. The CamMic source archive contains all three pinned upstream source archives. CamMic uses the libusbmuxd library API and does not build or bundle executable files for the GPL-licensed `iproxy` or other libusbmuxd command-line programs.

The complete libusbmuxd source archive also contains upstream source files for the separate `iproxy` and `inetcat` utilities. CamMic builds and distributes neither utility. Those source files are licensed under GPL-2.0-or-later; the GPL-2.0 text is included in `GPL-2.0-or-later-libusbmuxd-tools.txt` in the app and delivery archive.

## Corresponding source

The distribution archive contains `CamMic-Source-<commit>.tar.gz`, a source snapshot corresponding to the built binaries. It contains the CamMic source, exact BlackHole upstream commit, CamMic patch, build configuration, the pinned USBMux dependency sources, and license files. The same archive is bundled in `CamMic.app/Contents/Resources/`. For a specific build, the driver resource `CamMic-SOURCE.txt` and its build report identify the exact public GitHub source commit and direct archive URL.
