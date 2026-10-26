#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-installed}"
evidence="$repo_root/dist/cammic-coreaudio-validation"
build="$repo_root/.build/cammic-coreaudio-validation"
mkdir -p "$evidence" "$build"

if [[ "$mode" != "installed" && "$mode" != "install" ]]; then
    echo "Usage: $0 [installed|install]" >&2
    exit 2
fi

clang -std=c11 -O2 -Wall -Wextra "$repo_root/scripts/cammic-coreaudio-inspect.c" \
    -framework CoreAudio -framework CoreFoundation -o "$build/cammic-coreaudio-inspect"
clang -std=c11 -O2 -Wall -Wextra "$repo_root/scripts/test-cammic-coreaudio-loopback.c" \
    -framework CoreAudio -framework CoreFoundation -lm -o "$build/test-cammic-coreaudio-loopback"

if [[ "$mode" == "install" ]]; then
    [[ -f "$repo_root/dist/CamMicAudioDriver.pkg" ]] || {
        echo "Missing dist/CamMicAudioDriver.pkg; build the pinned CamMic HAL driver first." >&2
        exit 1
    }
    "$build/cammic-coreaudio-inspect" > "$evidence/device-inventory-preinstall.txt"
    /usr/bin/sudo /usr/sbin/installer -pkg "$repo_root/dist/CamMicAudioDriver.pkg" -target /
fi

driver="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
info="$driver/Contents/Info.plist"
[[ -d "$driver" ]] || { echo "CamMicAudio.driver is not installed at $driver" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.yykx682436.CamMicAudioDriver" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories:4b469f5a-1284-4ac8-b82c-75026d5ae711' "$info")" == "BlackHole_Create" ]]
/usr/bin/codesign --verify --deep --strict "$driver"

"$build/cammic-coreaudio-inspect" > "$evidence/device-inventory-before.txt"
"$build/test-cammic-coreaudio-loopback" "$evidence/cammic-known-signal-and-stop-silence.wav" \
    2>&1 | tee "$evidence/loopback-test.txt"
"$build/test-cammic-coreaudio-loopback" --capture-only "$evidence/cammic-capture-only-silence.wav" --expect-silence \
    2>&1 | tee "$evidence/capture-only-silence.txt"
"$build/cammic-coreaudio-inspect" > "$evidence/device-inventory-after.txt"

snapshot_unrelated_devices() {
    local source="$1" suffix="$2"
    /usr/bin/grep '^device id=' "$source" | /usr/bin/grep -v 'uid=CamMic2ch_' |
        /usr/bin/sed -E 's/^device id=[0-9]+/device id=OBJECT/' > "$build/devices-$suffix.txt" || true
    /usr/bin/grep '^plugin id=' "$source" | /usr/bin/grep -v 'bundleID=com.yykx682436.CamMicAudioDriver' |
        /usr/bin/sed -E 's/^plugin id=[0-9]+/plugin id=OBJECT/' > "$build/plugins-$suffix.txt" || true
    /usr/bin/grep -E '^default(Input|Output|SystemOutput) ' "$source" |
        /usr/bin/sed -E 's/^(default[^ ]+ )id=[0-9]+/\1id=OBJECT/' > "$build/defaults-$suffix-all.txt"
}

snapshot_unrelated_devices "$evidence/device-inventory-before.txt" after-install
snapshot_unrelated_devices "$evidence/device-inventory-after.txt" after-loopback
/usr/bin/cmp "$build/devices-after-install.txt" "$build/devices-after-loopback.txt"
/usr/bin/cmp "$build/plugins-after-install.txt" "$build/plugins-after-loopback.txt"
/usr/bin/cmp "$build/defaults-after-install-all.txt" "$build/defaults-after-loopback-all.txt"
if [[ -f "$evidence/device-inventory-preinstall.txt" ]]; then
    snapshot_unrelated_devices "$evidence/device-inventory-preinstall.txt" before-install
    /usr/bin/cmp "$build/devices-before-install.txt" "$build/devices-after-install.txt"
    /usr/bin/cmp "$build/plugins-before-install.txt" "$build/plugins-after-install.txt"
    /usr/bin/cmp "$build/defaults-before-install-all.txt" "$build/defaults-after-install-all.txt"
fi

echo "CoreAudio integration passed: public CamMic input, hidden output UID, owners/controls, shared clock, two distinct PCM signals, stop silence, restart isolation, and unchanged default devices."
