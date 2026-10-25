#!/bin/bash
set -euo pipefail

app_path="/Applications/CamMic.app"
legacy_app_path="/Applications/CamMic-Mac-arm64.app"
driver_path="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
app_bundle_id="com.yykx682436.CamMicMac"
driver_bundle_id="com.yykx682436.CamMicAudioDriver"
removed_driver=false

if [[ "$EUID" -ne 0 ]]; then
    exec /usr/bin/sudo /bin/bash "$0" "$@"
fi

bundle_id() {
    local bundle="$1"
    [[ -f "$bundle/Contents/Info.plist" ]] || return 1
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null
}

if [[ -e "$app_path" ]]; then
    if [[ "$(bundle_id "$app_path" || true)" == "$app_bundle_id" ]]; then
        /bin/rm -rf "$app_path"
    else
        echo "Leaving $app_path untouched because its bundle ID is not CamMic's." >&2
        exit 1
    fi
fi

if [[ -e "$legacy_app_path" ]]; then
    if [[ "$(bundle_id "$legacy_app_path" || true)" == "$app_bundle_id" ]]; then
        /bin/rm -rf "$legacy_app_path"
    else
        echo "Leaving $legacy_app_path untouched because its bundle ID is not CamMic's." >&2
        exit 1
    fi
fi

if [[ -e "$driver_path" ]]; then
    if [[ "$(bundle_id "$driver_path" || true)" == "$driver_bundle_id" ]]; then
        /bin/rm -rf "$driver_path"
        removed_driver=true
    else
        echo "Leaving $driver_path untouched because its bundle ID is not CamMic's." >&2
        exit 1
    fi
fi

/usr/sbin/pkgutil --forget com.yykx682436.CamMic.FullInstaller >/dev/null 2>&1 || true
/usr/sbin/pkgutil --forget com.yykx682436.CamMicAudioDriver >/dev/null 2>&1 || true

if [[ "$removed_driver" == true ]]; then
    /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod
    echo "CamMic was removed and CoreAudio restarted. Other audio drivers, including BlackHole, were left untouched."
else
    echo "CamMic.app was removed. No CamMic audio driver was present, so other audio devices were not changed."
fi
