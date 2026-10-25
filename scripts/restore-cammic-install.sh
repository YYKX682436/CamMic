#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/coreaudio-restart.sh"

recovery_root="/Library/Application Support/CamMic/Recovery"
app_path="/Applications/CamMic.app"
legacy_app_path="/Applications/CamMic-Mac-arm64.app"
driver_path="/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"
app_bundle_id="com.yykx682436.CamMicMac"
driver_bundle_id="com.yykx682436.CamMicAudioDriver"
legacy_bundle_id="com.yykx682436.CamMicMac"

if [[ "$EUID" -ne 0 ]]; then
    exec /usr/bin/sudo /bin/bash "$0" "$@"
fi

restore_item() {
    local destination="$1" relative="$2" recovery="$3"
    local state="$recovery/.state/$relative"
    [[ -f "$state" ]] || {
        echo "CamMic recovery is incomplete for $relative; no files were restored." >&2
        return 1
    }
    case "$(/bin/cat "$state")" in
        present)
            [[ -e "$recovery/$relative" ]] || {
                echo "CamMic backup is missing $relative; no files were restored." >&2
                return 1
            }
            /bin/rm -rf "$destination"
            /bin/mkdir -p "$(/usr/bin/dirname "$destination")"
            /usr/bin/ditto "$recovery/$relative" "$destination"
            ;;
        absent)
            /bin/rm -rf "$destination"
            ;;
        *)
            echo "CamMic recovery state is invalid for $relative; no files were restored." >&2
            return 1
            ;;
    esac
}

bundle_id() {
    local bundle="$1"
    [[ -f "$bundle/Contents/Info.plist" ]] || return 1
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null
}

restored=false
for type in full driver; do
    pointer="$recovery_root/.$type-recovery-path"
    [[ -f "$pointer" ]] || continue
    recovery="$(/bin/cat "$pointer")"
    case "$recovery" in
        "$recovery_root"/*) ;;
        *) echo "Invalid CamMic recovery path; leaving it untouched." >&2; exit 1 ;;
    esac
    if [[ "$type" == full ]]; then
        for relative in \
            "Applications/CamMic.app" \
            "Applications/CamMic-Mac-arm64.app" \
            "Library/Audio/Plug-Ins/HAL/CamMicAudio.driver"; do
            if [[ ! -f "$recovery/.state/$relative" ]]; then
                echo "CamMic full-install recovery is incomplete; no files were changed." >&2
                exit 1
            fi
            state="$(/bin/cat "$recovery/.state/$relative")"
            if [[ "$state" != "present" && "$state" != "absent" ]]; then
                echo "CamMic full-install recovery is invalid; no files were changed." >&2
                exit 1
            fi
            if [[ "$state" == "present" && ! -e "$recovery/$relative" ]]; then
                echo "CamMic full-install backup is incomplete; no files were changed." >&2
                exit 1
            fi
        done
        if [[ -e "$app_path" && "$(bundle_id "$app_path" || true)" != "$app_bundle_id" ]]; then
            echo "CamMic.app path is occupied by another bundle; recovery stopped without changing it." >&2
            exit 1
        fi
        if [[ -e "$legacy_app_path" && "$(bundle_id "$legacy_app_path" || true)" != "$legacy_bundle_id" ]]; then
            echo "Legacy app path is occupied by another bundle; recovery stopped without changing it." >&2
            exit 1
        fi
        if [[ -e "$driver_path" && "$(bundle_id "$driver_path" || true)" != "$driver_bundle_id" ]]; then
            echo "CamMic driver path is occupied by another bundle; recovery stopped without changing it." >&2
            exit 1
        fi
        restore_item "$app_path" "Applications/CamMic.app" "$recovery"
        restore_item "$legacy_app_path" "Applications/CamMic-Mac-arm64.app" "$recovery"
    else
        if [[ ! -f "$recovery/.state/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver" ]] ||
           [[ "$(/bin/cat "$recovery/.state/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver")" != "present" &&
              "$(/bin/cat "$recovery/.state/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver")" != "absent" ]]; then
            echo "CamMic driver recovery is incomplete; no files were changed." >&2
            exit 1
        fi
        if [[ "$(/bin/cat "$recovery/.state/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver")" == "present" &&
              ! -e "$recovery/Library/Audio/Plug-Ins/HAL/CamMicAudio.driver" ]]; then
            echo "CamMic driver backup is incomplete; no files were changed." >&2
            exit 1
        fi
        if [[ -e "$driver_path" && "$(bundle_id "$driver_path" || true)" != "$driver_bundle_id" ]]; then
            echo "CamMic driver path is occupied by another bundle; recovery stopped without changing it." >&2
            exit 1
        fi
    fi
    restore_item "$driver_path" "Library/Audio/Plug-Ins/HAL/CamMicAudio.driver" "$recovery"
    /bin/rm -f "$pointer"
    restored=true
    echo "Restored the previous CamMic state from $recovery. Recovery data was kept."
done

if [[ "$restored" == true ]]; then
    restart_core_audio
else
    echo "No incomplete CamMic installation was found."
fi
