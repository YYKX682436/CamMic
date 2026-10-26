#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  echo "Set DEVELOPER_DIR to Xcode 15.4's Contents/Developer directory." >&2
  exit 1
fi
version="$(xcodebuild -version)"
if [[ "$version" != $'Xcode 15.4\nBuild version 15F31d' ]]; then
  echo "Expected Xcode 15.4 (15F31d); found: $version" >&2
  exit 1
fi
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "$sdk" != "17.5" ]]; then
  echo "Expected iOS 17.5 SDK; found: $sdk" >&2
  exit 1
fi

derived="$repo_root/.build/usb-probe-derived"
dist="$repo_root/dist"
mkdir -p "$dist" "$repo_root/.build"
xcodebuild \
  -project CamMic.xcodeproj \
  -scheme CamMic \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build | tee "$repo_root/.build/usb-probe-ios-build.log"

ios_app="$derived/Build/Products/Debug-iphoneos/CamMic.app"
[[ -f "$ios_app/CamMic" ]] || { echo "Missing Debug iPhone app executable." >&2; exit 1; }
minimum="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$ios_app/Info.plist")"
[[ "$minimum" == "14.0" ]] || { echo "Unexpected iOS minimum version: $minimum" >&2; exit 1; }
if codesign --verify "$ios_app" 2>/dev/null; then
  echo "Expected an unsigned Debug app for the existing device-signing flow." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$ios_app" "$stage/Payload/CamMic.app"
ios_ipa="$dist/CamMic-USBProbe-Debug-iOS14-unsigned.ipa"
rm -f "$ios_ipa"
(cd "$stage" && ditto -c -k --sequesterRsrc --keepParent Payload "$ios_ipa")

triple="arm64-apple-macosx13.0"
mac_scratch="$repo_root/.build/usb-probe-mac"
swift build --package-path "$repo_root" --scratch-path "$mac_scratch" \
  --configuration debug --triple "$triple" --product CamMicMac
mac_bin_path="$(swift build --package-path "$repo_root" --scratch-path "$mac_scratch" \
  --configuration debug --triple "$triple" --product CamMicMac --show-bin-path)"
mac_binary="$mac_bin_path/CamMicMac"
[[ -f "$mac_binary" ]] || { echo "Missing Debug Mac app executable." >&2; exit 1; }
[[ "$(lipo -archs "$mac_binary")" == "arm64" ]] || { echo "Expected arm64 Debug Mac app." >&2; exit 1; }

mac_app="$dist/CamMic-USBProbe-Debug.app"
mac_zip="$dist/CamMic-USBProbe-Debug-macOS-arm64.zip"
rm -rf "$mac_app" "$mac_zip"
mkdir -p "$mac_app/Contents/MacOS" "$mac_app/Contents/Resources"
ditto "$mac_binary" "$mac_app/Contents/MacOS/CamMicMac"
cp Assets/CamMic.icns "$mac_app/Contents/Resources/CamMic.icns"
cat > "$mac_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>CamMic USB Probe Debug</string>
  <key>CFBundleExecutable</key><string>CamMicMac</string>
  <key>CFBundleIconFile</key><string>CamMic.icns</string>
  <key>CFBundleIdentifier</key><string>com.yykx682436.CamMicMac.usbprobe.debug</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>CamMic USB Probe Debug</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.2-debug-probe</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>CamMic USB probe uses the loopback ports forwarded by USBMux.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$mac_app"
codesign --verify --deep --strict "$mac_app"
ditto -c -k --sequesterRsrc --keepParent "$mac_app" "$mac_zip"

printf 'Debug iPhone IPA: %s\n' "$ios_ipa"
printf 'Debug Mac app archive: %s\n' "$mac_zip"
printf 'USB probe ports: localhost 50889 (init), localhost 50890 (TLS audio)\n'
printf 'Release app targets and Release installer are not modified by this step.\n'
