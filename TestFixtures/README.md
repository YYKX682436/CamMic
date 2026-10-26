# Previous release upgrade fixture

`CamMic-Installer-0.5.0-06d0737.pkg` is the actual combined 0.5.0 installer built from frozen baseline commit `06d07373bde2b9a7f4ac63a731600c0af72cf67d` by [GitHub Actions run 40324555673](https://github.com/YYKX682436/CamMic/actions/runs/40324555673). SHA-256 is pinned in the adjacent `.sha256` file. CI verifies the checksum and the embedded CamMic Bundle ID, version, and build before using this package to test the 0.5.0 → 0.6.0 upgrade, failed-upgrade recovery, repeated installation, and uninstall. This CI-only historical installer is intentionally excluded from the public source archive; the original source and checksum remain in the repository's `TestFixtures/` directory.

The 0.5.0 installer includes the corresponding source archive and license notices. Earlier 0.3.2 and 0.4.0 installer fixtures were removed; the frozen source history remains intact.
