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
component_plist="$build_root/components.plist"
component_inspection="$build_root/component-inspection"
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
rm -rf "$full_root" "$full_scripts" "$component_inspection" "$distribution"
/bin/rm -f "$component_plist"
mkdir -p "$full_root/Applications" "$full_root/Library/Audio/Plug-Ins/HAL" "$full_scripts" "$distribution_resources"
ditto "$app" "$full_root/Applications/CamMic.app"
ditto "$driver" "$full_root/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
cp "$repo_root/packaging/scripts/recovery-common.sh" "$full_scripts/recovery-common.sh"
cp "$repo_root/scripts/coreaudio-restart.sh" "$full_scripts/coreaudio-restart.sh"
cp "$repo_root/scripts/restore-cammic-install.sh" "$full_scripts/restore-cammic-install.sh"
cp "$repo_root/packaging/scripts/full-preinstall" "$full_scripts/preinstall"
cp "$repo_root/packaging/scripts/full-postinstall" "$full_scripts/postinstall"
chmod 755 "$full_scripts/preinstall" "$full_scripts/postinstall"

pkgbuild --analyze --root "$full_root" "$component_plist"
component_index=0
component_count=0
while relative_path="$(/usr/libexec/PlistBuddy -c "Print :$component_index:RootRelativeBundlePath" "$component_plist" 2>/dev/null)"; do
    case "$relative_path" in
        "Applications/CamMic.app"|"Library/Audio/Plug-Ins/HAL/CamMicAudio.driver")
            if /usr/libexec/PlistBuddy -c "Print :$component_index:BundleIsRelocatable" "$component_plist" >/dev/null 2>&1; then
                /usr/libexec/PlistBuddy -c "Set :$component_index:BundleIsRelocatable false" "$component_plist"
            else
                /usr/libexec/PlistBuddy -c "Add :$component_index:BundleIsRelocatable bool false" "$component_plist"
            fi
            ;;
        *)
            echo "Unexpected bundle in CamMic installer payload: $relative_path" >&2
            exit 1
            ;;
    esac
    component_index=$((component_index + 1))
    component_count=$((component_count + 1))
done
[[ "$component_count" -eq 2 ]] || {
    echo "Expected the CamMic app and driver in the installer component plist." >&2
    exit 1
}

pkgbuild \
    --root "$full_root" \
    --component-plist "$component_plist" \
    --scripts "$full_scripts" \
    --install-location / \
    --identifier "com.yykx682436.CamMic.FullInstaller" \
    --version "0.4.0" \
    --ownership recommended \
    "$build_root/CamMic-component.pkg"

pkgutil --expand "$build_root/CamMic-component.pkg" "$component_inspection"
relocation_entries="$(/usr/bin/awk '/<relocate>/{inside=1; next} /<\/relocate>/{inside=0} inside {print}' "$component_inspection/PackageInfo")"
if [[ "$relocation_entries" == *"com.yykx682436.CamMicMac"* || "$relocation_entries" == *"com.yykx682436.CamMicAudioDriver"* ]]; then
    echo "CamMic installer bundles must stay at their declared component paths." >&2
    exit 1
fi

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
cp "$repo_root/LICENSES/GPL-2.0-or-later-libusbmuxd-tools.txt" "$distribution_resources/LICENSE-GPL-2.0-or-later-libusbmuxd-tools.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$distribution_resources/LICENSE-BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$distribution_resources/THIRD_PARTY_NOTICES.md"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libusbmuxd.txt" "$distribution_resources/"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libimobiledevice-glue.txt" "$distribution_resources/"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libplist.txt" "$distribution_resources/"
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
cp "$repo_root/LICENSES/GPL-2.0-or-later-libusbmuxd-tools.txt" "$delivery/LICENSE-GPL-2.0-or-later-libusbmuxd-tools.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$delivery/LICENSE-BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$delivery/THIRD_PARTY_NOTICES.md"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libusbmuxd.txt" "$delivery/"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libimobiledevice-glue.txt" "$delivery/"
cp "$app/Contents/Resources/LICENSES/LGPL-2.1-libplist.txt" "$delivery/"
cp "$repo_root/Driver/UPSTREAM.md" "$delivery/DRIVER-UPSTREAM.md"
cp "$repo_root/README.md" "$delivery/README.md"
cp "$repo_root/docs/安装与使用.md" "$delivery/INSTALL.zh-CN.md"
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
