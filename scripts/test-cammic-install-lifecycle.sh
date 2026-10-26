#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$repo_root/dist/cammic-install-lifecycle-validation"
build="$repo_root/.build/cammic-install-lifecycle"
legacy_installer="${1:-}"
installer="${2:-}"
previous_release_sha256="614b147a940c9539174a96eb348ee64f122da1c903485849d8c298da3348dcfc"
app="/Applications/CamMic.app"
driver="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
mkdir -p "$evidence" "$build"

root_path_exists() {
    /usr/bin/sudo /bin/bash -c '[[ -e "$1" ]]' cammic-test "$1"
}

root_regular_file_exists() {
    /usr/bin/sudo /bin/bash -c '[[ -f "$1" ]]' cammic-test "$1"
}

[[ -f "$legacy_installer" ]] || { echo "Pass the real previous-version CamMic installer as argument 1." >&2; exit 1; }
[[ -f "$installer" ]] || { echo "Pass the current CamMic-Installer.pkg as argument 2." >&2; exit 1; }
actual_legacy_sha256="$(/usr/bin/shasum -a 256 "$legacy_installer" | /usr/bin/awk '{print $1}')"
[[ "$actual_legacy_sha256" == "$previous_release_sha256" ]] || {
    echo "The upgrade test requires the pinned 0.5.0 package from 06d0737; SHA-256 mismatch." >&2
    exit 1
}
legacy_expand="$build/legacy-expanded"
/bin/rm -rf "$legacy_expand"
/usr/sbin/pkgutil --expand-full "$legacy_installer" "$legacy_expand"
legacy_app_plist="$(/usr/bin/find "$legacy_expand" -path '*/CamMic.app/Contents/Info.plist' -type f -print -quit)"
[[ -f "$legacy_app_plist" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$legacy_app_plist")" == "0.5.0" && \
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$legacy_app_plist")" == "5" && \
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$legacy_app_plist")" == "com.yykx682436.CamMicMac" ]] || {
    echo "The previous-version fixture must contain the actual CamMic 0.5.0 app from 06d0737." >&2
    exit 1
}
/bin/rm -rf "$legacy_expand"
clang -std=c11 -O2 -Wall -Wextra "$repo_root/scripts/cammic-coreaudio-inspect.c" \
    -framework CoreAudio -framework CoreFoundation -o "$build/cammic-coreaudio-inspect"

python3 "$repo_root/scripts/cammic-coreaudio-inventory.py" self-test

snapshot() {
    local label="$1"
    local raw="$evidence/$label-inventory.txt"
    "$build/cammic-coreaudio-inspect" > "$raw"
    python3 "$repo_root/scripts/cammic-coreaudio-inventory.py" snapshot "$raw" "$evidence/$label-summary.json"
}

verify_cammic_state() {
    local label="$1"
    local expected="$2"
    local raw="$evidence/$label-inventory.txt"
    if [[ "$expected" == "present" ]]; then
        /usr/bin/grep -Eq '^device id=[0-9]+ name=CamMic uid=CamMic2ch_UID ' "$raw"
        /usr/bin/grep -Eq '^translateUID=CamMic2ch_2_UID status=0 device=[1-9][0-9]*$' "$raw"
        /usr/bin/grep -Eq '^translateBundleID=com\.yykx682436\.CamMicAudioDriver status=ok plugin=[1-9][0-9]* ' "$raw"
    else
        if /usr/bin/grep -Eq '^device id=[0-9]+ name=CamMic uid=CamMic2ch_UID ' "$raw" ||
           /usr/bin/grep -Eq '^translateUID=CamMic2ch_2_UID status=0 device=[1-9][0-9]*$' "$raw" ||
           /usr/bin/grep -Eq '^translateBundleID=com\.yykx682436\.CamMicAudioDriver status=ok plugin=[1-9][0-9]* ' "$raw"; then
            echo "CamMic endpoints remained registered after uninstall." >&2
            exit 1
        fi
    fi
}

compare_unrelated_state() {
    local expected="$1" actual="$2"
    python3 "$repo_root/scripts/cammic-coreaudio-inventory.py" compare \
        "$evidence/$expected-summary.json" "$evidence/$actual-summary.json"
}

verify_app_version() {
    local expected="$1"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
    [[ "$actual" == "$expected" ]] || {
        echo "Expected CamMic.app $expected but found $actual." >&2
        exit 1
    }
}

verify_app_build() {
    local expected="$1"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
    [[ "$actual" == "$expected" ]] || {
        echo "Expected CamMic.app build $expected but found $actual." >&2
        exit 1
    }
}

verify_current_payload() {
    local framework
    local expected_framework
    verify_app_version "0.6.0"
    verify_app_build "6"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "com.yykx682436.CamMicMac" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")" == "com.yykx682436.CamMicAudioDriver" ]]
    cmp "$repo_root/dist/CamMic.app/Contents/MacOS/CamMicMac" "$app/Contents/MacOS/CamMicMac"
    local framework_count=0
    for framework in "$app"/Contents/Frameworks/*.dylib; do
        [[ -f "$framework" ]] || { echo "Missing bundled USBMux runtime libraries." >&2; exit 1; }
        expected_framework="$repo_root/dist/CamMic.app/Contents/Frameworks/$(basename "$framework")"
        [[ -f "$expected_framework" ]] || { echo "Unexpected installed runtime library: $framework" >&2; exit 1; }
        cmp "$expected_framework" "$framework"
        framework_count=$((framework_count + 1))
    done
    [[ "$framework_count" -eq 3 ]] || { echo "Expected all three bundled USBMux libraries; found $framework_count." >&2; exit 1; }
    /usr/bin/otool -L "$app/Contents/MacOS/CamMicMac" | /usr/bin/grep -Fq '@executable_path/../Frameworks/libusbmuxd-2.0.' || {
        echo "Installed CamMic does not load the bundled libusbmuxd runtime." >&2
        exit 1
    }
    for framework in "$app"/Contents/Frameworks/*.dylib; do
        if /usr/bin/otool -L "$framework" | /usr/bin/grep -Eq '/opt/homebrew/|/usr/local/Cellar/'; then
            echo "Installed USBMux runtime depends on an external Homebrew path: $framework" >&2
            exit 1
        fi
    done
}

verify_blackhole_unchanged() {
    local phase="$1"
    if [[ -f "$evidence/blackhole-files-before.txt" ]]; then
        [[ -d "$blackhole_bundle" && -f "$blackhole_binary" ]] || {
            echo "CamMic $phase removed the installed BlackHole driver bundle." >&2
            exit 1
        }
        /usr/bin/shasum -a 256 "$blackhole_binary" > "$evidence/blackhole-binary-$phase.txt"
        /usr/bin/cmp "$evidence/blackhole-binary-before.txt" "$evidence/blackhole-binary-$phase.txt"
        python3 - "$blackhole_bundle" "$evidence/blackhole-files-$phase.txt" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
lines = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root).as_posix()}\n")
destination.write_text("".join(lines))
PY
        /usr/bin/cmp "$evidence/blackhole-files-before.txt" "$evidence/blackhole-files-$phase.txt"
    else
        [[ ! -e "$blackhole_bundle" ]] || {
            echo "BlackHole2ch appeared during CamMic $phase; stop before treating the package as isolated." >&2
            exit 1
        }
    fi
}

snapshot before

blackhole_binary="/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver/Contents/MacOS/BlackHole"
blackhole_bundle="/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
if [[ -f "$blackhole_binary" ]]; then
    blackhole_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver/Contents/Info.plist")"
    [[ "$blackhole_id" == "audio.existential.BlackHole2ch" ]] || {
        echo "BlackHole2ch.driver has unexpected bundle ID $blackhole_id; stopping before installation." >&2
        exit 1
    }
    printf '%s\n' "$blackhole_id" > "$evidence/blackhole-bundle-id.txt"
    /usr/bin/shasum -a 256 "$blackhole_binary" > "$evidence/blackhole-binary-before.txt"
    python3 - "$blackhole_bundle" "$evidence/blackhole-files-before.txt" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
lines = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    lines.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(root).as_posix()}\n")
destination.write_text("".join(lines))
PY
fi

/usr/bin/sudo /usr/sbin/installer -pkg "$legacy_installer" -target /
verify_app_version "0.5.0"
verify_app_build "5"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "com.yykx682436.CamMicMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")" == "com.yykx682436.CamMicAudioDriver" ]]
snapshot installed-previous-0.5.0
verify_cammic_state installed-previous-0.5.0 present
compare_unrelated_state before installed-previous-0.5.0
verify_blackhole_unchanged after-install-legacy

# Exercise the package postinstall rollback with the same payload except for a
# deliberately invalid app signature. The valid 0.5.0 installation must return.
failed_root="$build/failed-upgrade-root"
failed_package="$build/CamMic-invalid-signature.pkg"
failed_pointer="/Library/Application Support/CamMic/Recovery/.full-recovery-path"
rm -rf "$failed_root" "$failed_package"
mkdir -p "$failed_root/Applications" "$failed_root/Library/Audio/Plug-Ins/HAL"
ditto "$repo_root/dist/CamMic.app" "$failed_root/Applications/CamMic.app"
rm -rf "$failed_root/Applications/CamMic.app/Contents/_CodeSignature"
ditto "$repo_root/.build/cammic-audio-driver/CamMicAudio.driver" \
    "$failed_root/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
pkgbuild \
    --root "$failed_root" \
    --component-plist "$repo_root/.build/cammic-installer/components.plist" \
    --scripts "$repo_root/.build/cammic-installer/full-scripts" \
    --install-location / \
    --identifier "com.yykx682436.CamMic.FullInstaller" \
    --version "0.6.0" \
    --ownership recommended \
    "$failed_package"
if /usr/bin/sudo /usr/sbin/installer -pkg "$failed_package" -target /; then
    echo "The deliberately invalid CamMic signature unexpectedly installed successfully." >&2
    exit 1
fi
verify_app_version "0.5.0"
verify_app_build "5"
[[ -d "$app" && -d "$driver" ]] || {
    echo "A failed CamMic upgrade did not restore the previous app and HAL driver." >&2
    exit 1
}
if root_regular_file_exists "$failed_pointer"; then
    /usr/bin/sudo /bin/bash "$repo_root/scripts/restore-cammic-install.sh"
    if root_path_exists "$failed_pointer"; then
        echo "The recovery command did not clear the resolved transaction pointer." >&2
        exit 1
    fi
fi
snapshot failed-upgrade-rolled-back
verify_cammic_state failed-upgrade-rolled-back present
compare_unrelated_state installed-previous-0.5.0 failed-upgrade-rolled-back
verify_blackhole_unchanged after-failed-upgrade

# Simulate an install interrupted immediately after preinstall has backed up
# the known CamMic bundles and recorded its recovery pointer. Use the exact
# staged script directory supplied to pkgbuild so its sibling helpers resolve
# as they do when Installer runs the package scripts.
/usr/bin/sudo /bin/bash "$repo_root/.build/cammic-installer/full-scripts/preinstall"
if ! root_regular_file_exists "$failed_pointer"; then
    echo "The interrupted CamMic install did not leave its recovery pointer." >&2
    exit 1
fi
interrupted_recovery="$(/usr/bin/sudo /bin/cat "$failed_pointer")"
for destination in "$app" "$driver"; do
    if root_path_exists "$destination"; then
        echo "The interrupted CamMic preinstall did not remove its target: $destination" >&2
        /usr/bin/sudo /bin/ls -ld "$destination" >&2
        exit 1
    fi
done
for relative in "Applications/CamMic.app" "Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"; do
    state_file="$interrupted_recovery/.state/$relative"
    backup_item="$interrupted_recovery/$relative"
    if ! root_regular_file_exists "$state_file" ||
       [[ "$(/usr/bin/sudo /bin/cat "$state_file")" != "present" ]] ||
       ! root_path_exists "$backup_item"; then
        echo "The interrupted CamMic install did not preserve its previous $relative payload." >&2
        exit 1
    fi
done
/usr/bin/sudo /bin/bash "$repo_root/scripts/restore-cammic-install.sh"
if root_path_exists "$failed_pointer"; then
    echo "The recovery command did not clear the resolved interrupted-install pointer." >&2
    exit 1
fi
verify_app_version "0.5.0"
verify_app_build "5"
snapshot restored-previous-0.5.0
verify_cammic_state restored-previous-0.5.0 present
compare_unrelated_state installed-previous-0.5.0 restored-previous-0.5.0
verify_blackhole_unchanged after-manual-recovery

/usr/bin/sudo /usr/sbin/installer -pkg "$installer" -target /
verify_current_payload
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "com.yykx682436.CamMicMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist")" == "CamMic" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" == "CamMic.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")" == "com.yykx682436.CamMicAudioDriver" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$driver/Contents/Info.plist")" == "CamMic.icns" ]]
cmp "$repo_root/Assets/CamMic.icns" "$app/Contents/Resources/CamMic.icns"
cmp "$repo_root/Assets/CamMic.icns" "$driver/Contents/Resources/CamMic.icns"
snapshot upgraded-to-current
verify_cammic_state upgraded-to-current present
compare_unrelated_state before upgraded-to-current
verify_blackhole_unchanged after-upgrade

/usr/bin/sudo /usr/sbin/installer -pkg "$installer" -target /
verify_current_payload
snapshot repeated-current-install
verify_cammic_state repeated-current-install present
compare_unrelated_state upgraded-to-current repeated-current-install
verify_blackhole_unchanged after-repeat-install

/usr/bin/sudo /bin/bash "$repo_root/scripts/uninstall-cammic.sh"
snapshot uninstalled
verify_cammic_state uninstalled absent
compare_unrelated_state before uninstalled
[[ ! -e "$app" && ! -e "$driver" ]]
verify_blackhole_unchanged after-uninstall

echo "CamMic 0.5.0-to-0.6.0 upgrade from the actual 06d0737 installer, failed-upgrade rollback, interrupted-install recovery, repeated installation, and CamMic-only uninstall preserved unrelated CoreAudio devices, plug-ins, and defaults."
