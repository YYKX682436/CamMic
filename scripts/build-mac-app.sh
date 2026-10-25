#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

triple="arm64-apple-macosx13.0"
scratch="$repo_root/.build/mac-app"
dist="$repo_root/dist"
mkdir -p "$dist"

swift build --package-path "$repo_root" --scratch-path "$scratch" \
  --configuration release --triple "$triple"
bin_path="$(swift build --package-path "$repo_root" --scratch-path "$scratch" \
  --configuration release --triple "$triple" --show-bin-path)"
binary="$bin_path/CamMicMac"
[[ -f "$binary" ]] || { echo "Missing CamMicMac executable at $binary" >&2; exit 1; }
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == "arm64" ]] || { echo "Expected arm64 executable; found $architectures" >&2; exit 1; }

source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
output="$dist/CamMic-Mac-arm64.app"
mkdir -p "$output/Contents/MacOS"
ditto "$binary" "$output/Contents/MacOS/CamMicMac"
cat > "$output/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>CamMic Mac Receiver</string>
  <key>CFBundleExecutable</key><string>CamMicMac</string>
  <key>CFBundleIdentifier</key><string>com.yykx682436.CamMicMac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>CamMic Mac Receiver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>CamMic Mac Receiver connects to the paired iPhone on your local network to receive microphone audio.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# This is an ad-hoc local signature, not Developer ID distribution or notarization.
codesign --force --deep --sign - "$output"
codesign --verify --deep --strict "$output"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$output/Contents/Info.plist")"
[[ "$minimum" == "13.0" ]] || { echo "Unexpected minimum macOS version: $minimum" >&2; exit 1; }

zip="$dist/CamMic-Mac-arm64-${short_revision}-$$.zip"
ditto -c -k --sequesterRsrc --keepParent "$output" "$zip"

report="$dist/mac-build-report.txt"
{
  printf 'Source: %s\n' "$source_revision"
  printf 'Swift: %s\n' "$(swift --version | head -1)"
  printf 'Architecture: %s\n' "$architectures"
  printf 'Minimum macOS: %s\n' "$minimum"
  printf 'Signature: ad-hoc; no Developer ID or notarization\n'
  printf 'External audio driver bundled: no\n'
  printf 'Mach-O build version:\n'
  xcrun vtool -show-build "$output/Contents/MacOS/CamMicMac"
  printf 'App SHA-256: '
  shasum -a 256 "$output/Contents/MacOS/CamMicMac" | awk '{print $1}'
  printf 'Zip SHA-256: '
  shasum -a 256 "$zip" | awk '{print $1}'
} | tee "$report"

echo "Created $output and $zip"
