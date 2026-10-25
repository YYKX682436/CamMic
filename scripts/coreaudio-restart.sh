#!/bin/bash
set -euo pipefail

restart_core_audio() {
    local pgrep_bin="${1:-/usr/bin/pgrep}"
    local killall_bin="${2:-/usr/bin/killall}"
    local sleep_bin="${3:-/bin/sleep}"
    local previous_pid current_pid attempt

    previous_pid="$("$pgrep_bin" -x coreaudiod 2>/dev/null | /usr/bin/head -n 1)" || previous_pid=""
    if [[ -z "$previous_pid" ]]; then
        echo "CoreAudio was not running; the CamMic driver will load when the service starts."
        return 0
    fi

    if ! "$killall_bin" -TERM coreaudiod; then
        echo "Could not request a CoreAudio restart." >&2
        return 1
    fi

    for ((attempt = 0; attempt < 50; attempt++)); do
        current_pid="$("$pgrep_bin" -x coreaudiod 2>/dev/null | /usr/bin/head -n 1)" || current_pid=""
        if [[ -n "$current_pid" && "$current_pid" != "$previous_pid" ]]; then
            echo "CoreAudio restarted and is ready to load CamMic's audio driver."
            return 0
        fi
        "$sleep_bin" 0.1
    done

    echo "CoreAudio did not restart after it was stopped; relaunch audio apps or restart the Mac before using CamMic." >&2
    return 1
}
