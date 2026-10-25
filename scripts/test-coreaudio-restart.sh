#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/cammic-coreaudio-restart.XXXXXX")"
trap '/bin/rm -rf "$scratch"' EXIT
source "$repo_root/scripts/coreaudio-restart.sh"

/usr/bin/printf '0\n' > "$scratch/calls"
cat > "$scratch/pgrep" <<'MOCK'
#!/bin/bash
set -euo pipefail
calls="$(/bin/cat "$CAMMIC_TEST_CALLS")"
calls=$((calls + 1))
/usr/bin/printf '%s\n' "$calls" > "$CAMMIC_TEST_CALLS"
case "$CAMMIC_TEST_MODE:$calls" in
    restart:1) echo 1234 ;;
    restart:*) echo 5678 ;;
    timeout:*) echo 1234 ;;
    none:*) exit 1 ;;
esac
MOCK
cat > "$scratch/killall" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == "-TERM" && "$2" == "coreaudiod" ]]
[[ "${CAMMIC_TEST_KILLALL_FAIL:-0}" != "1" ]] || exit 1
/usr/bin/touch "$CAMMIC_TEST_KILLED"
MOCK
cat > "$scratch/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
/bin/chmod 755 "$scratch/pgrep" "$scratch/killall" "$scratch/sleep"

CAMMIC_TEST_MODE=restart CAMMIC_TEST_CALLS="$scratch/calls" CAMMIC_TEST_KILLED="$scratch/killed" \
    restart_core_audio "$scratch/pgrep" "$scratch/killall" "$scratch/sleep" >/dev/null
[[ -f "$scratch/killed" ]]

/usr/bin/printf '0\n' > "$scratch/calls"
if CAMMIC_TEST_MODE=restart CAMMIC_TEST_CALLS="$scratch/calls" CAMMIC_TEST_KILLED="$scratch/kill-failed" CAMMIC_TEST_KILLALL_FAIL=1 \
    restart_core_audio "$scratch/pgrep" "$scratch/killall" "$scratch/sleep" >/dev/null 2>&1; then
    echo "Expected a failure when CoreAudio could not be stopped." >&2
    exit 1
fi
[[ ! -e "$scratch/kill-failed" ]]

/usr/bin/printf '0\n' > "$scratch/calls"
CAMMIC_TEST_MODE=none CAMMIC_TEST_CALLS="$scratch/calls" CAMMIC_TEST_KILLED="$scratch/none-killed" \
    restart_core_audio "$scratch/pgrep" "$scratch/killall" "$scratch/sleep" >/dev/null
[[ ! -e "$scratch/none-killed" ]]

/usr/bin/printf '0\n' > "$scratch/calls"
if CAMMIC_TEST_MODE=timeout CAMMIC_TEST_CALLS="$scratch/calls" CAMMIC_TEST_KILLED="$scratch/timeout-killed" \
    restart_core_audio "$scratch/pgrep" "$scratch/killall" "$scratch/sleep" >/dev/null 2>&1; then
    echo "Expected a failure when CoreAudio does not return with a new PID." >&2
    exit 1
fi
[[ -f "$scratch/timeout-killed" ]]

echo "CoreAudio restart helper checks passed (restart, stop failure, inactive service, and timeout)."
