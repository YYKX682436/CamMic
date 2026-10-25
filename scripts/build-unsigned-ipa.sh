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

derived="$repo_root/DerivedData"
dist="$repo_root/dist"
mkdir -p "$dist"
xcodebuild \
  -project CamMic.xcodeproj \
  -scheme CamMic \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  build | tee "$dist/build.log"

app="$derived/Build/Products/Release-iphoneos/CamMic.app"
binary="$app/CamMic"
[[ -f "$binary" ]] || { echo "Missing app executable" >&2; exit 1; }
minimum="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")"
[[ "$minimum" == "14.0" ]] || { echo "Unexpected minimum iOS version: $minimum" >&2; exit 1; }
architectures="$(lipo -archs "$binary")"
[[ "$architectures" == "arm64" ]] || { echo "Unexpected architectures: $architectures" >&2; exit 1; }
if [[ -d "$app/Frameworks" ]] && [[ -n "$(find "$app/Frameworks" -mindepth 1 -print -quit)" ]]; then
  echo "Unexpected embedded frameworks; inspect their minimum OS before delivery." >&2
  exit 1
fi
if codesign --verify "$app" 2>/dev/null; then
  echo "Expected an unsigned app for the existing resigning workflow." >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/CamMic.app"
ipa="$dist/CamMic-iOS14-unsigned.ipa"
rm -f "$ipa"
(cd "$stage" && ditto -c -k --sequesterRsrc --keepParent Payload "$ipa")

{
  printf 'Source: %s\n' "$(git rev-parse HEAD)"
  printf 'Toolchain: %s\n' "$(echo "$version" | tr '\n' ' ')"
  printf 'SDK: iOS %s\n' "$sdk"
  printf 'MinimumOSVersion: %s\n' "$minimum"
  printf 'Architectures: %s\n' "$architectures"
  printf 'Signature: unsigned\n'
  printf 'Embedded frameworks: none\n'
  printf 'Mach-O build version:\n'
  xcrun vtool -show-build "$binary"
  printf 'Linked libraries:\n'
  otool -L "$binary"
  printf 'IPA SHA-256: '
  shasum -a 256 "$ipa" | awk '{print $1}'
} | tee "$dist/build-report.txt"

echo "Created $ipa"
