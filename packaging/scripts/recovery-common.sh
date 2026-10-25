#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/coreaudio-restart.sh"

APP_PATH="/Applications/CamMic.app"
LEGACY_APP_PATH="/Applications/CamMic-Mac-arm64.app"
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
OLD_APP_BUNDLE_ID="com.yykx682436.CamMicMac"
APP_BUNDLE_ID="com.yykx682436.CamMicMac"
DRIVER_BUNDLE_ID="com.yykx682436.CamMicAudioDriver"
RECOVERY_ROOT="/Library/Application Support/CamMic/Recovery"

bundle_id() {
    local bundle="$1"
    [[ -f "$bundle/Contents/Info.plist" ]] || return 1
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null
}

backup_item() {
    local source="$1" relative="$2" destination="$3"
    local state="$destination/.state/$relative"
    /bin/mkdir -p "$(/usr/bin/dirname "$state")"
    if [[ -e "$source" ]]; then
        /bin/mkdir -p "$destination/$(/usr/bin/dirname "$relative")"
        /usr/bin/ditto "$source" "$destination/$relative"
        /usr/bin/printf 'present\n' > "$state"
    else
        /usr/bin/printf 'absent\n' > "$state"
    fi
}

restore_item() {
    local destination="$1" relative="$2" backup="$3"
    local state="$backup/.state/$relative"
    [[ -f "$state" ]] || {
        echo "CamMic recovery is incomplete for $relative; leaving $destination untouched." >&2
        return 1
    }
    case "$(/bin/cat "$state")" in
        present)
            [[ -e "$backup/$relative" ]] || {
                echo "CamMic backup is missing $relative; leaving $destination untouched." >&2
                return 1
            }
            /bin/rm -rf "$destination"
            /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
            /usr/bin/ditto "$backup/$relative" "$destination"
            ;;
        absent)
            /bin/rm -rf "$destination"
            ;;
        *)
            echo "CamMic recovery state is invalid for $relative; leaving $destination untouched." >&2
            return 1
            ;;
    esac
}

set_owner() {
    local path="$1"
    /usr/sbin/chown -R root:wheel "$path"
}
