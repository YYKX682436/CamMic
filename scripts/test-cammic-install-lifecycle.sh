#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$repo_root/dist/cammic-install-lifecycle-validation"
build="$repo_root/.build/cammic-install-lifecycle"
legacy_installer="${1:-}"
installer="${2:-}"
app="/Applications/CamMic.app"
driver="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
mkdir -p "$evidence" "$build"

[[ -f "$legacy_installer" ]] || { echo "Pass the real previous-version CamMic installer as argument 1." >&2; exit 1; }
[[ -f "$installer" ]] || { echo "Pass the current CamMic-Installer.pkg as argument 2." >&2; exit 1; }
legacy_expand="$build/legacy-expanded"
/bin/rm -rf "$legacy_expand"
/usr/sbin/pkgutil --expand-full "$legacy_installer" "$legacy_expand"
legacy_app_plist="$(/usr/bin/find "$legacy_expand" -path '*/CamMic.app/Contents/Info.plist' -type f -print -quit)"
[[ -f "$legacy_app_plist" && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$legacy_app_plist")" == "0.3.1" ]] || {
    echo "The previous-version fixture must contain a CamMic 0.3.1 app payload." >&2
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
verify_app_version "0.3.1"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "com.yykx682436.CamMicMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")" == "com.yykx682436.CamMicAudioDriver" ]]
snapshot installed-legacy-0.3.1
verify_cammic_state installed-legacy-0.3.1 present
compare_unrelated_state before installed-legacy-0.3.1
verify_blackhole_unchanged after-install-legacy

/usr/bin/sudo /usr/sbin/installer -pkg "$installer" -target /
verify_app_version "0.3.2"
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
verify_app_version "0.3.2"
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

echo "CamMic 0.3.1-to-0.3.2 upgrade, repeated 0.3.2 installation, and CamMic-only uninstall preserved unrelated CoreAudio devices, plug-ins, and defaults."
