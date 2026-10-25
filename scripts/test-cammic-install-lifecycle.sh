#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
evidence="$repo_root/dist/cammic-install-lifecycle-validation"
build="$repo_root/.build/cammic-install-lifecycle"
installer="$repo_root/dist/CamMic-Installer.pkg"
app="/Applications/CamMic.app"
driver="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
mkdir -p "$evidence" "$build"

[[ -f "$installer" ]] || { echo "Missing final CamMic-Installer.pkg." >&2; exit 1; }
clang -std=c11 -O2 -Wall -Wextra "$repo_root/scripts/cammic-coreaudio-inspect.c" \
    -framework CoreAudio -framework CoreFoundation -o "$build/cammic-coreaudio-inspect"

snapshot() {
    local label="$1"
    local raw="$evidence/$label-inventory.txt"
    "$build/cammic-coreaudio-inspect" > "$raw"
    python3 - "$raw" "$evidence/$label-summary.txt" <<'PY'
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text().splitlines()
devices = []
plugins = []
defaults = {}
for line in source:
    match = re.match(r'^device id=\d+ name=(.*?) uid=(.*?) manufacturer=(.*?) input=(\??\d+) output=(\??\d+) hidden=(\??\d+) running=\??\d+ transport=(\??0x[0-9a-fA-F]+)', line)
    if match:
        name, uid, manufacturer, inputs, outputs, hidden, transport = match.groups()
        if not uid.startswith('CamMic'):
            devices.append({"uid": uid, "name": name, "manufacturer": manufacturer,
                            "inputChannels": inputs, "outputChannels": outputs,
                            "hidden": hidden, "transport": transport})
        continue
    match = re.match(r'^plugin id=\d+ class=([0-9a-fA-F]+) bundleID=(.*)$', line)
    if match:
        class_id, bundle = match.groups()
        if bundle != 'com.yykx682436.CamMicAudioDriver':
            plugins.append({"class": class_id, "bundleID": bundle})
        continue
    match = re.match(r'^(defaultInput|defaultOutput|defaultSystemOutput) id=\d+ name=(.*?) uid=(.*)$', line)
    if match:
        defaults[match.group(1)] = {"name": match.group(2), "uid": match.group(3)}
result = {"devices": sorted(devices, key=lambda item: item["uid"]),
          "plugins": sorted(plugins, key=lambda item: item["bundleID"]),
          "defaults": defaults}
pathlib.Path(sys.argv[2]).write_text(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
PY
}

verify_cammic_state() {
    local label="$1" expected="$2" raw="$evidence/$label-inventory.txt"
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
    /usr/bin/cmp "$evidence/$expected-summary.txt" "$evidence/$actual-summary.txt"
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

/usr/bin/sudo /usr/sbin/installer -pkg "$installer" -target /
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "com.yykx682436.CamMicMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist")" == "CamMic" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" == "CamMic.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")" == "com.yykx682436.CamMicAudioDriver" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$driver/Contents/Info.plist")" == "CamMic.icns" ]]
cmp "$repo_root/Assets/CamMic.icns" "$app/Contents/Resources/CamMic.icns"
cmp "$repo_root/Assets/CamMic.icns" "$driver/Contents/Resources/CamMic.icns"
snapshot installed-once
verify_cammic_state installed-once present
compare_unrelated_state before installed-once
verify_blackhole_unchanged after-install-once

/usr/bin/sudo /usr/sbin/installer -pkg "$installer" -target /
snapshot installed-twice
verify_cammic_state installed-twice present
compare_unrelated_state installed-once installed-twice
verify_blackhole_unchanged after-install-twice

/usr/bin/sudo /bin/bash "$repo_root/scripts/uninstall-cammic.sh"
snapshot uninstalled
verify_cammic_state uninstalled absent
compare_unrelated_state before uninstalled
[[ ! -e "$app" && ! -e "$driver" ]]
verify_blackhole_unchanged after-uninstall

echo "CamMic install, repeat install, and uninstall preserved all unrelated CoreAudio devices, plug-ins, and defaults."
