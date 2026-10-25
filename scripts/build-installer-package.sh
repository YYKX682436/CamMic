#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "Build the installer from a clean, committed source revision." >&2
    exit 1
fi
source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
app="$repo_root/dist/CamMic.app"
driver="$repo_root/.build/cammic-audio-driver/CamMicAudio.driver"
source_archive="$repo_root/dist/CamMic-Source-$(git rev-parse --short=12 HEAD).tar.gz"
dist="$repo_root/dist"
build_root="$repo_root/.build/cammic-installer"
full_root="$build_root/full-root"
full_scripts="$build_root/full-scripts"
distribution="$build_root/distribution"
distribution_resources="$distribution/Resources"

[[ -d "$app" ]] || { echo "Build dist/CamMic.app first." >&2; exit 1; }
[[ -d "$driver" ]] || { echo "Build the CamMic audio driver first." >&2; exit 1; }
[[ -f "$source_archive" ]] || { echo "Build the matching CamMic source archive first." >&2; exit 1; }
[[ -f "$dist/mac-build-report.txt" ]] && grep -Fqx "Source: $source_revision" "$dist/mac-build-report.txt" || {
    echo "The CamMic.app build report does not match this source revision." >&2
    exit 1
}
[[ -f "$dist/audio-driver-build-report.txt" ]] && grep -Fqx "CamMic source: $source_revision" "$dist/audio-driver-build-report.txt" || {
    echo "The CamMic driver build report does not match this source revision." >&2
    exit 1
}
app_source="$app/Contents/Resources/$(basename "$source_archive")"
app_driver="$app/Contents/Resources/CamMicAudioDriver.pkg"
[[ -f "$app_source" ]] && cmp -s "$source_archive" "$app_source" || {
    echo "CamMic.app does not contain the corresponding complete source archive." >&2
    exit 1
}
[[ -f "$app_driver" ]] && cmp -s "$repo_root/dist/CamMicAudioDriver.pkg" "$app_driver" || {
    echo "CamMic.app does not contain the corresponding CamMic driver installer." >&2
    exit 1
}
rm -rf "$full_root" "$full_scripts" "$distribution"
mkdir -p "$full_root/Applications" "$full_root/Library/Audio/Plug-Ins/HAL" "$full_scripts" "$distribution_resources"
ditto "$app" "$full_root/Applications/CamMic.app"
ditto "$driver" "$full_root/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
cp "$repo_root/packaging/scripts/recovery-common.sh" "$full_scripts/recovery-common.sh"
cp "$repo_root/scripts/coreaudio-restart.sh" "$full_scripts/coreaudio-restart.sh"
cp "$repo_root/packaging/scripts/full-preinstall" "$full_scripts/preinstall"
cp "$repo_root/packaging/scripts/full-postinstall" "$full_scripts/postinstall"
chmod 755 "$full_scripts/preinstall" "$full_scripts/postinstall"

pkgbuild \
    --root "$full_root" \
    --scripts "$full_scripts" \
    --install-location / \
    --identifier "com.yykx682436.CamMic.FullInstaller" \
    --version "0.3.0" \
    --ownership recommended \
    "$build_root/CamMic-component.pkg"

cp "$repo_root/packaging/installer/Distribution.xml" "$distribution/Distribution.xml"
cp "$repo_root/packaging/installer/welcome.html" "$distribution_resources/welcome.html"
cp "$repo_root/packaging/installer/conclusion.html" "$distribution_resources/conclusion.html"
source_url="https://github.com/YYKX682436/CamMic/archive/$source_revision.tar.gz"
sed \
    -e "s|@SOURCE_REVISION@|$source_revision|g" \
    -e "s|@SOURCE_URL@|$source_url|g" \
    "$repo_root/packaging/installer/notices.html" > "$distribution_resources/notices.html"
cp "$repo_root/LICENSE" "$distribution_resources/LICENSE-GPL-3.0.txt"
cp "$repo_root/LICENSES/MIT-CamMic-original.txt" "$distribution_resources/LICENSE-MIT-CamMic-original.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$distribution_resources/LICENSE-BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$distribution_resources/THIRD_PARTY_NOTICES.md"
productbuild \
    --distribution "$distribution/Distribution.xml" \
    --resources "$distribution_resources" \
    --package-path "$build_root" \
    "$dist/CamMic-Installer.pkg"

delivery="$build_root/CamMic-macOS-arm64-$short_revision"
rm -rf "$delivery"
mkdir -p "$delivery"
ditto "$app" "$delivery/CamMic.app"
cp "$dist/CamMic-Installer.pkg" "$delivery/CamMic-Installer.pkg"
cp "$dist/CamMicAudioDriver.pkg" "$delivery/CamMicAudioDriver.pkg"
cp "$source_archive" "$delivery/$(basename "$source_archive")"
cp "$repo_root/scripts/uninstall-cammic.sh" "$delivery/uninstall-cammic.sh"
cp "$repo_root/scripts/restore-cammic-install.sh" "$delivery/restore-cammic-install.sh"
cp "$repo_root/scripts/coreaudio-restart.sh" "$delivery/coreaudio-restart.sh"
cp "$repo_root/LICENSE" "$delivery/LICENSE-GPL-3.0.txt"
cp "$repo_root/LICENSES/MIT-CamMic-original.txt" "$delivery/LICENSE-MIT-CamMic-original.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$delivery/LICENSE-BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$delivery/THIRD_PARTY_NOTICES.md"
cp "$repo_root/Driver/UPSTREAM.md" "$delivery/DRIVER-UPSTREAM.md"
cp "$repo_root/README.md" "$delivery/README.md"
cp "$repo_root/Assets/CamMicIcon.svg" "$delivery/CamMicIcon.svg"
cp "$repo_root/Assets/CamMicIcon-1024.png" "$delivery/CamMicIcon-preview.png"
cp "$repo_root/Assets/CamMicIcon-macOS-1024.png" "$delivery/CamMicIcon-macOS-preview.png"

archive="$dist/CamMic-macOS-arm64-$short_revision.zip"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$delivery" "$archive"

report="$dist/installer-build-report.txt"
{
    printf 'Source: %s\n' "$(git rev-parse HEAD)"
    printf 'Application: %s\n' "$app"
    printf 'Combined installer: %s\n' "$dist/CamMic-Installer.pkg"
    printf 'Standalone driver installer: %s\n' "$dist/CamMicAudioDriver.pkg"
    printf 'Corresponding source: %s\n' "$source_archive"
    printf 'Uninstaller: %s\n' "$delivery/uninstall-cammic.sh"
    printf 'Package signature: unsigned; no Developer ID or notarization\n'
    printf 'Archive SHA-256: '
    shasum -a 256 "$archive" | awk '{print $1}'
    printf 'Installer SHA-256: '
    shasum -a 256 "$dist/CamMic-Installer.pkg" | awk '{print $1}'
} | tee "$report"

echo "Created $dist/CamMic-Installer.pkg and $archive"
