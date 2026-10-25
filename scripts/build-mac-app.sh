#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

triple="arm64-apple-macosx13.0"
scratch="$repo_root/.build/mac-app"
dist="$repo_root/dist"
source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
source_archive="$dist/CamMic-Source-$(git rev-parse --short=12 HEAD).tar.gz"
working_tree_clean=true
revision_suffix=""
source_label="$source_revision"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  working_tree_clean=false
  revision_suffix="-worktree"
  source_label="$source_revision (working tree modified)"
fi
mkdir -p "$dist"

swift build --package-path "$repo_root" --scratch-path "$scratch" \
  --configuration release --triple "$triple" --product CamMicMac
bin_path="$(swift build --package-path "$repo_root" --scratch-path "$scratch" \
  --configuration release --triple "$triple" --product CamMicMac --show-bin-path)"
binary="$bin_path/CamMicMac"
[[ -f "$binary" ]] || { echo "Missing CamMicMac executable at $binary" >&2; exit 1; }
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == "arm64" ]] || { echo "Expected arm64 executable; found $architectures" >&2; exit 1; }

output="$dist/CamMic.app"
rm -rf "$output"
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources/LICENSES"
ditto "$binary" "$output/Contents/MacOS/CamMicMac"
cp "$repo_root/Assets/CamMic.icns" "$output/Contents/Resources/CamMic.icns"
cp "$repo_root/LICENSE" "$output/Contents/Resources/LICENSES/GPL-3.0.txt"
cp "$repo_root/LICENSES/MIT-CamMic-original.txt" "$output/Contents/Resources/LICENSES/MIT-CamMic-original.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$output/Contents/Resources/LICENSES/BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$output/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$repo_root/Driver/UPSTREAM.md" "$output/Contents/Resources/DRIVER-UPSTREAM.md"
embedded_source=false
embedded_driver_installer=false
if [[ "$working_tree_clean" == true && -f "$source_archive" ]]; then
  cp "$source_archive" "$output/Contents/Resources/$(basename "$source_archive")"
  embedded_source=true
fi
if [[ "$working_tree_clean" == true && -f "$dist/CamMicAudioDriver.pkg" &&
      -f "$dist/audio-driver-build-report.txt" ]] &&
   grep -Fqx "CamMic source: $source_revision" "$dist/audio-driver-build-report.txt"; then
  cp "$dist/CamMicAudioDriver.pkg" "$output/Contents/Resources/CamMicAudioDriver.pkg"
  embedded_driver_installer=true
fi

cat > "$output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>CamMic</string>
  <key>CFBundleExecutable</key><string>CamMicMac</string>
  <key>CFBundleIconFile</key><string>CamMic.icns</string>
  <key>CFBundleIdentifier</key><string>com.yykx682436.CamMicMac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>CamMic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>CamMic connects to the paired iPhone on your local network to receive microphone audio.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# This is an ad-hoc local signature, not Developer ID distribution or notarization.
codesign --force --deep --sign - --timestamp=none "$output"
codesign --verify --deep --strict "$output"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$output/Contents/Info.plist")"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$output/Contents/Info.plist")"
bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$output/Contents/Info.plist")"
[[ "$minimum" == "13.0" ]] || { echo "Unexpected minimum macOS version: $minimum" >&2; exit 1; }
[[ "$display_name" == "CamMic" && "$bundle_name" == "CamMic" ]] || { echo "Unexpected Finder/Dock app name." >&2; exit 1; }

zip="$dist/CamMic-macOS-arm64-$short_revision$revision_suffix.zip"
ditto -c -k --sequesterRsrc --keepParent "$output" "$zip"

report="$dist/mac-build-report.txt"
{
  printf 'Source: %s\n' "$source_label"
  printf 'Swift: %s\n' "$(swift --version | head -1)"
  printf 'Architecture: %s\n' "$architectures"
  printf 'Bundle name: %s\n' "$bundle_name"
  printf 'Display name: %s\n' "$display_name"
  printf 'Bundle ID: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")"
  printf 'Minimum macOS: %s\n' "$minimum"
  printf 'Signature: ad-hoc; no Developer ID or notarization\n'
  printf 'Embedded CamMic driver installer: %s\n' "$embedded_driver_installer"
  printf 'Embedded corresponding source: %s\n' "$embedded_source"
  printf 'Mach-O build version:\n'
  xcrun vtool -show-build "$output/Contents/MacOS/CamMicMac"
  printf 'App SHA-256: '
  shasum -a 256 "$output/Contents/MacOS/CamMicMac" | awk '{print $1}'
  printf 'Zip SHA-256: '
  shasum -a 256 "$zip" | awk '{print $1}'
} | tee "$report"

echo "Created $output and $zip"
