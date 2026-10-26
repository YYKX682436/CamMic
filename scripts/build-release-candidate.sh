#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "Build the public candidate from a clean, committed source revision." >&2
    exit 1
fi

source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
dist="$repo_root/dist"
ipa="$dist/CamMic-iOS14-unsigned.ipa"
mac_zip="$dist/CamMic-macOS-arm64.zip"
source_archive="$dist/CamMic-Source-$short_revision.tar.gz"
manifest="$dist/release-build-report.txt"
candidate="$dist/release-candidate"

for report in build-report.txt mac-build-report.txt audio-driver-build-report.txt installer-build-report.txt; do
    [[ -f "$dist/$report" ]] || { echo "Missing $dist/$report" >&2; exit 1; }
done
for report in build-report.txt mac-build-report.txt audio-driver-build-report.txt installer-build-report.txt; do
    if ! /usr/bin/grep -Fqx "Source: $source_revision" "$dist/$report" &&
       ! /usr/bin/grep -Fqx "CamMic source: $source_revision" "$dist/$report"; then
        echo "The report $report does not identify source revision $source_revision." >&2
        exit 1
    fi
done
[[ -f "$ipa" && -f "$mac_zip" && -f "$source_archive" ]] || {
    echo "The iOS IPA, Mac ZIP, or matching source archive is missing." >&2
    exit 1
}

temp="$(mktemp -d "${TMPDIR:-/tmp}/cammic-candidate.XXXXXX")"
trap 'rm -rf "$temp"' EXIT

unzip -q "$ipa" -d "$temp/ipa"
ios_app="$temp/ipa/Payload/CamMic.app"
[[ -d "$ios_app" ]] || { echo "The IPA is missing Payload/CamMic.app." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ios_app/Info.plist")" == "com.yykx682436.CamMic" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ios_app/Info.plist")" == "0.6.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ios_app/Info.plist")" == "4" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$ios_app/Info.plist")" == "14.0" ]]
[[ "$(lipo -archs "$ios_app/CamMic")" == "arm64" ]]
if codesign --verify "$ios_app" >/dev/null 2>&1; then
    echo "The public iOS IPA must remain unsigned." >&2
    exit 1
fi

unzip -q "$mac_zip" -d "$temp/mac"
delivery="$temp/mac/CamMic-macOS-arm64"
[[ -d "$delivery" ]] || { echo "The Mac ZIP has an unexpected root folder." >&2; exit 1; }
[[ -f "$delivery/$(basename "$source_archive")" ]] || {
    echo "The Mac ZIP does not contain the matching source archive." >&2
    exit 1
}
/usr/bin/grep -Fqx 'Mac: version 0.6.0 (build 6), minimum macOS 13.0, arm64' "$delivery/BUILD-MANIFEST.txt"
/usr/bin/grep -Fqx 'iPhone: version 0.6.0 (build 4), minimum iOS 14.0, arm64, unsigned' "$delivery/BUILD-MANIFEST.txt"
/usr/bin/grep -Fqx "Source revision: $source_revision" "$delivery/BUILD-MANIFEST.txt"
cmp "$source_archive" "$delivery/$(basename "$source_archive")"
pkg_payload="$temp/installer-expanded"
pkgutil --expand-full "$delivery/CamMic-Installer.pkg" "$pkg_payload"
mac_app_info="$(find "$pkg_payload" -path '*/CamMic.app/Contents/Info.plist' -type f -print -quit)"
[[ -f "$mac_app_info" ]] || { echo "The Mac installer is missing its CamMic.app payload." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$mac_app_info")" == "com.yykx682436.CamMicMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mac_app_info")" == "0.6.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mac_app_info")" == "6" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$mac_app_info")" == "13.0" ]]
mac_app="$(/usr/bin/dirname "$(/usr/bin/dirname "$mac_app_info")")"
[[ "$(lipo -archs "$mac_app/Contents/MacOS/CamMicMac")" == "arm64" ]]
pkg_source="$(find "$mac_app/Contents/Resources" -maxdepth 1 -name "$(basename "$source_archive")" -type f -print -quit)"
[[ -f "$pkg_source" ]] || { echo "The app in the installer lacks its matching source archive." >&2; exit 1; }
cmp "$source_archive" "$pkg_source"
grep -Fq 'version="0.6.0"' "$pkg_payload/Distribution"
(
    cd "$delivery"
    shasum -a 256 -c SHA256SUMS
)

/bin/rm -rf "$candidate"
mkdir -p "$candidate"
cp "$ipa" "$candidate/CamMic-iOS14-unsigned.ipa"
cp "$mac_zip" "$candidate/CamMic-macOS-arm64.zip"
(
    cd "$candidate"
    shasum -a 256 CamMic-iOS14-unsigned.ipa CamMic-macOS-arm64.zip > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
[[ "$(find "$candidate" -maxdepth 1 -type f | wc -l | tr -d ' ')" == "3" ]] || {
    echo "The public candidate must expose exactly the IPA, Mac ZIP, and SHA256SUMS." >&2
    exit 1
}

{
    printf 'Source revision: %s\n' "$source_revision"
    printf 'iOS: 0.6.0 (4); minimum 14.0; arm64; unsigned\n'
    printf 'Mac: 0.6.0 (6); minimum 13.0; arm64\n'
    printf 'Candidate files:\n'
    cat "$candidate/SHA256SUMS"
    printf 'SHA256SUMS file SHA-256: '
    shasum -a 256 "$candidate/SHA256SUMS" | awk '{print $1}'
} | tee "$manifest"

echo "Prepared exactly three public candidate files in $candidate"
