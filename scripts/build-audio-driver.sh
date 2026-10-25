#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xcode_version="$(xcodebuild -version)"
if [[ "$xcode_version" != $'Xcode 15.4\nBuild version 15F31d' ]]; then
    echo "Expected Xcode 15.4 (15F31d); found: $xcode_version" >&2
    exit 1
fi

source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
build_root="$repo_root/.build/cammic-audio-driver"
source_copy="$build_root/BlackHole-v0.7.1"
derived_data="$build_root/DerivedData"
dist="$repo_root/dist"
package_root="$build_root/package-root"
package_scripts="$build_root/package-scripts"
mkdir -p "$dist" "$build_root"
rm -rf "$source_copy" "$derived_data" "$package_root" "$package_scripts"
grep -Fqx '#define kDriver_Name "CamMic"' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice_Name "CamMic"' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice2_Name "CamMicInternalOutput"' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice_HasInput true' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice_HasOutput false' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice2_HasInput false' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kDevice2_HasOutput true' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kCanBeDefaultDevice false' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '#define kCanBeDefaultSystemDevice false' "$repo_root/Driver/CamMicDriverConfig.h"
grep -Fqx '    static let publicInputName = "CamMic"' "$repo_root/MacApp/AudioDevices.swift"
grep -Fqx '    static let hiddenOutputName = "CamMicInternalOutput"' "$repo_root/MacApp/AudioDevices.swift"
grep -Fqx '    static let publicInputUID = "CamMic2ch_UID"' "$repo_root/MacApp/AudioDevices.swift"
grep -Fqx '    static let hiddenOutputUID = "CamMic2ch_2_UID"' "$repo_root/MacApp/AudioDevices.swift"
grep -Fqx '    static let modelUID = "CamMic2ch_ModelUID"' "$repo_root/MacApp/AudioDevices.swift"
ditto "$repo_root/Driver/BlackHole-v0.7.1" "$source_copy"
patch --batch --fuzz=0 -p1 -d "$source_copy" < "$repo_root/Driver/patches/blackhole-cammic.patch"
cp "$repo_root/Driver/CamMicDriverConfig.h" "$source_copy/BlackHole/CamMicDriverConfig.h"
cp "$repo_root/Assets/CamMic.icns" "$source_copy/BlackHole/CamMic.icns"

build_log="$build_root/xcodebuild.log"
xcodebuild \
    -project "$source_copy/BlackHole.xcodeproj" \
    -target BlackHole \
    -configuration Release \
    -sdk macosx \
    -derivedDataPath "$derived_data" \
    -xcconfig "$repo_root/Driver/CamMicAudioDriver.xcconfig" \
    PRODUCT_BUNDLE_IDENTIFIER="com.yykx682436.CamMicAudioDriver" \
    PRODUCT_NAME=CamMicAudio \
    MARKETING_VERSION=0.7.1 \
    GCC_PREFIX_HEADER="$source_copy/BlackHole/CamMicDriverConfig.h" \
    ARCHS='arm64 x86_64' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    DEVELOPMENT_TEAM= \
    build | tee "$build_log"

driver="$derived_data/Build/Products/Release/CamMicAudio.driver"
[[ -d "$driver" ]] || { echo "Missing CamMicAudio.driver at $driver" >&2; exit 1; }
info="$driver/Contents/Info.plist"
binary="$driver/Contents/MacOS/CamMicAudio"
[[ -f "$binary" ]] || { echo "Missing CamMic audio plug-in executable" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.yykx682436.CamMicAudioDriver" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")" == "CamMicAudio" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info")" == "CamMic.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories:4b469f5a-1284-4ac8-b82c-75026d5ae711' "$info")" == "BlackHole_Create" ]]
[[ -f "$driver/Contents/Resources/CamMic.icns" ]]
[[ -f "$driver/Contents/Resources/LICENSE" ]]
[[ ! -e "$driver/Contents/Resources/README.md" ]]
cp "$repo_root/LICENSES/BlackHole-v0.7.1.txt" "$driver/Contents/Resources/BlackHole-v0.7.1.txt"
cp "$repo_root/LICENSES/THIRD_PARTY_NOTICES.md" "$driver/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$repo_root/LICENSES/MIT-CamMic-original.txt" "$driver/Contents/Resources/MIT-CamMic-original.txt"
cat > "$driver/Contents/Resources/CamMic-SOURCE.txt" <<SOURCE
CamMic audio driver source revision: $source_revision
Corresponding complete source archive: https://github.com/YYKX682436/CamMic/archive/$source_revision.tar.gz
The source tree includes the pinned BlackHole v0.7.1 source, CamMic configuration, exact patch, and license notices.
SOURCE

architectures="$(lipo -archs "$binary")"
for architecture in arm64 x86_64; do
    [[ " $architectures " == *" $architecture "* ]] || {
        echo "Expected a universal HAL driver including $architecture; found: $architectures" >&2
        exit 1
    }
done

# HAL plugins require a code signature. This local ad-hoc signature does not assert
# Developer ID identity and is not notarized.
codesign --force --deep --sign - --timestamp=none "$driver"
codesign --verify --deep --strict "$driver"
ditto "$driver" "$build_root/CamMicAudio.driver"

mkdir -p "$package_root" "$package_scripts"
ditto "$driver" "$package_root/CamMicAudio.driver"
cp "$repo_root/packaging/scripts/recovery-common.sh" "$package_scripts/recovery-common.sh"
cp "$repo_root/packaging/scripts/driver-preinstall" "$package_scripts/preinstall"
cp "$repo_root/packaging/scripts/driver-postinstall" "$package_scripts/postinstall"
chmod 755 "$package_scripts/preinstall" "$package_scripts/postinstall"
pkgbuild \
    --root "$package_root" \
    --scripts "$package_scripts" \
    --install-location "/Library/Audio/Plug-Ins/HAL" \
    --identifier "com.yykx682436.CamMicAudioDriver" \
    --version "0.3.0" \
    --ownership recommended \
    "$dist/CamMicAudioDriver.pkg"

report="$dist/audio-driver-build-report.txt"
{
    printf 'CamMic source: %s\n' "$source_revision"
    printf 'BlackHole upstream: v0.7.1 e2b22aaaba4e507a097131704bf96dabc004d9cf\n'
    printf 'HAL bundle: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$driver/Contents/Info.plist")"
    printf 'Bundle ID: %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")"
    printf 'Factory UUID: 4b469f5a-1284-4ac8-b82c-75026d5ae711\n'
    printf 'Public microphone UID: CamMic2ch_UID\n'
    printf 'Hidden output UID: CamMic2ch_2_UID\n'
    printf 'Model UID: CamMic2ch_ModelUID\n'
    printf 'Architectures: %s\n' "$architectures"
    printf 'Xcode: %s\n' "$(echo "$xcode_version" | tr '\n' ' ')"
    printf 'Signature: ad-hoc; not Developer ID signed or notarized\n'
    printf 'Driver SHA-256: '
    shasum -a 256 "$binary" | awk '{print $1}'
    printf 'Installer SHA-256: '
    shasum -a 256 "$dist/CamMicAudioDriver.pkg" | awk '{print $1}'
} | tee "$report"

echo "Built $driver and $dist/CamMicAudioDriver.pkg"
