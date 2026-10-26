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
dependency_prefix="$repo_root/.build/usbmuxd-deps/prefix"
working_tree_clean=true
revision_suffix=""
source_label="$source_revision"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  working_tree_clean=false
  revision_suffix="-worktree"
  source_label="$source_revision (working tree modified)"
fi
mkdir -p "$dist"
if [[ ! -f "$dependency_prefix/lib/pkgconfig/libusbmuxd-2.0.pc" ]]; then
  "$repo_root/scripts/build-usbmuxd-dependencies.sh"
fi
export PKG_CONFIG_PATH="$dependency_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources/LICENSES" \
  "$output/Contents/Resources/THIRD_PARTY_SOURCE" "$output/Contents/Frameworks"
ditto "$binary" "$output/Contents/MacOS/CamMicMac"
cp "$repo_root/Assets/CamMic.icns" "$output/Contents/Resources/CamMic.icns"
cmp "$repo_root/Assets/CamMic.icns" "$output/Contents/Resources/CamMic.icns"
cp "$repo_root/LICENSE" "$output/Contents/Resources/LICENSES/GPL-3.0.txt"
cp "$repo_root/LICENSES/MIT-CamMic-original.txt" "$output/Contents/Resources/LICENSES/MIT-CamMic-original.txt"
cp "$repo_root/LICENSES/GPL-2.0-or-later-libusbmuxd-tools.txt" "$output/Contents/Resources/LICENSES/GPL-2.0-or-later-libusbmuxd-tools.txt"
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$output/Contents/Resources/LICENSES/BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$output/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$repo_root/Driver/UPSTREAM.md" "$output/Contents/Resources/DRIVER-UPSTREAM.md"
cp "$repo_root/Vendor/SourceArchives/"*.tar.gz "$output/Contents/Resources/THIRD_PARTY_SOURCE/"

command -v pkg-config >/dev/null || { echo "pkgconf is required to stage the USBMux runtime libraries." >&2; exit 1; }
[[ "$(pkg-config --modversion libusbmuxd-2.0)" == "2.1.1" ]] || {
  echo "Expected libusbmuxd 2.1.1 for the pinned CamMic USB transport." >&2
  exit 1
}
[[ "$(pkg-config --modversion libplist-2.0)" == "2.8.0" ]] || {
  echo "Expected libplist 2.8.0 for the pinned CamMic USB transport." >&2
  exit 1
}
[[ "$(pkg-config --modversion libimobiledevice-glue-1.0)" == "1.3.3" ]] || {
  echo "Expected libimobiledevice-glue 1.3.3 for the pinned CamMic USB transport." >&2
  exit 1
}

usbmuxd_libdir="$(pkg-config --variable=libdir libusbmuxd-2.0)"
plist_libdir="$(pkg-config --variable=libdir libplist-2.0)"
glue_libdir="$(pkg-config --variable=libdir libimobiledevice-glue-1.0)"
usbmuxd_library="$(find "$usbmuxd_libdir" -maxdepth 1 -type f -name 'libusbmuxd-2.0.*.dylib' -print -quit)"
plist_library="$(find "$plist_libdir" -maxdepth 1 -type f -name 'libplist-2.0.*.dylib' -print -quit)"
glue_library="$(find "$glue_libdir" -maxdepth 1 -type f -name 'libimobiledevice-glue-1.0.*.dylib' -print -quit)"
[[ -f "$usbmuxd_library" && -f "$plist_library" && -f "$glue_library" ]] || {
  echo "Could not locate all pinned USBMux runtime libraries." >&2
  exit 1
}

for source_library in "$usbmuxd_library" "$plist_library" "$glue_library"; do
  library_architectures="$(lipo -archs "$source_library")"
  [[ " $library_architectures " == *" arm64 "* ]] || {
    echo "A bundled USBMux library has no arm64 slice: $source_library" >&2
    exit 1
  }
  library_build="$(vtool -show-build "$source_library")"
  grep -Fq "minos 13.0" <<< "$library_build" || {
    echo "A bundled USBMux library is not compatible with macOS 13: $source_library" >&2
    exit 1
  }
done

for source_library in "$usbmuxd_library" "$plist_library" "$glue_library"; do
  library_name="$(basename "$source_library")"
  destination="$output/Contents/Frameworks/$library_name"
  cp "$source_library" "$destination"
  install_name_tool -id "@rpath/$library_name" "$destination"
done

for library_name in "$(basename "$usbmuxd_library")" "$(basename "$plist_library")" "$(basename "$glue_library")"; do
  destination="$output/Contents/Frameworks/$library_name"
  while IFS= read -r dependency; do
    dependency_name="$(basename "$dependency")"
    case "$dependency_name" in
      libusbmuxd-2.0.*.dylib|libplist-2.0.*.dylib|libimobiledevice-glue-1.0.*.dylib)
        install_name_tool -change "$dependency" "@loader_path/$dependency_name" "$destination"
        ;;
    esac
  done < <(otool -L "$destination" | tail -n +2 | awk '{print $1}')
done

while IFS= read -r dependency; do
  dependency_name="$(basename "$dependency")"
  case "$dependency_name" in
    libusbmuxd-2.0.*.dylib)
      install_name_tool -change "$dependency" "@executable_path/../Frameworks/$dependency_name" "$output/Contents/MacOS/CamMicMac"
      ;;
  esac
done < <(otool -L "$output/Contents/MacOS/CamMicMac" | tail -n +2 | awk '{print $1}')

if otool -L "$output/Contents/MacOS/CamMicMac" "$output/Contents/Frameworks/"*.dylib | rg -q '/opt/homebrew/|/usr/local/Cellar/'; then
  echo "A bundled USBMux library still depends on a Homebrew installation path." >&2
  exit 1
fi

tar -xOf "$repo_root/Vendor/SourceArchives/libusbmuxd-2.1.1.tar.gz" libusbmuxd-2.1.1/COPYING \
  > "$output/Contents/Resources/LICENSES/LGPL-2.1-libusbmuxd.txt"
tar -xOf "$repo_root/Vendor/SourceArchives/libimobiledevice-glue-1.3.3.tar.gz" libimobiledevice-glue-1.3.3/COPYING \
  > "$output/Contents/Resources/LICENSES/LGPL-2.1-libimobiledevice-glue.txt"
tar -xOf "$repo_root/Vendor/SourceArchives/libplist-2.8.0.tar.gz" libplist-2.8.0/COPYING.LESSER \
  > "$output/Contents/Resources/LICENSES/LGPL-2.1-libplist.txt"
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
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key><string>CamMic can receive microphone audio over the local network when you choose advanced Wi-Fi mode. USB mode uses the trusted USB device connection.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# This is an ad-hoc local signature, not Developer ID distribution or notarization.
codesign --force --deep --sign - --timestamp=none "$output"
codesign --verify --deep --strict "$output"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$output/Contents/Info.plist")"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$output/Contents/Info.plist")"
bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$output/Contents/Info.plist")"
icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$output/Contents/Info.plist")"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$output/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$output/Contents/Info.plist")"
[[ "$minimum" == "13.0" ]] || { echo "Unexpected minimum macOS version: $minimum" >&2; exit 1; }
[[ "$display_name" == "CamMic" && "$bundle_name" == "CamMic" ]] || { echo "Unexpected Finder/Dock app name." >&2; exit 1; }
[[ "$icon_file" == "CamMic.icns" ]] || { echo "Unexpected Finder/Dock icon resource: $icon_file" >&2; exit 1; }
[[ "$marketing_version" == "0.6.0" && "$build_number" == "6" ]] || {
  echo "Expected CamMic Mac 0.6.0 (6); found $marketing_version ($build_number)." >&2
  exit 1
}

report="$dist/mac-build-report.txt"
{
  printf 'Source: %s\n' "$source_label"
  printf 'Swift: %s\n' "$(swift --version | head -1)"
  printf 'Architecture: %s\n' "$architectures"
  printf 'Bundle name: %s\n' "$bundle_name"
  printf 'Display name: %s\n' "$display_name"
  printf 'Icon resource: %s (matches alpha-preserving source ICNS)\n' "$icon_file"
  printf 'Bundle ID: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$output/Contents/Info.plist")"
  printf 'Version: %s (%s)\n' "$marketing_version" "$build_number"
  printf 'Minimum macOS: %s\n' "$minimum"
  printf 'Signature: ad-hoc; no Developer ID or notarization\n'
  printf 'Embedded CamMic driver installer: %s\n' "$embedded_driver_installer"
  printf 'Embedded corresponding source: %s\n' "$embedded_source"
  printf 'Embedded USBMux runtime: libusbmuxd 2.1.1, libimobiledevice-glue 1.3.3, libplist 2.8.0\n'
  printf 'Mach-O build version:\n'
  xcrun vtool -show-build "$output/Contents/MacOS/CamMicMac"
  printf 'App SHA-256: '
  shasum -a 256 "$output/Contents/MacOS/CamMicMac" | awk '{print $1}'
} | tee "$report"

echo "Created $output"
