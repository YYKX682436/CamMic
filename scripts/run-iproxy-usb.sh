#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 <target-iPhone-UDID>" >&2
  exit 2
fi
udid="$1"
if ! command -v iproxy >/dev/null 2>&1; then
  echo "iproxy is missing. Install the official libusbmuxd package, then retry." >&2
  exit 127
fi

help_text="$(iproxy --help 2>&1 || true)"
if [[ "$help_text" == *"LOCAL_PORT:DEVICE_PORT"* ]]; then
  # Explicitly select USB and keep every Mac-side forwarding socket on loopback.
  exec iproxy --local --udid "$udid" --source 127.0.0.1 \
    50888:50888 50889:50889 50890:50890
elif [[ "$help_text" == *"LOCAL_TCP_PORT DEVICE_TCP_PORT"* ]]; then
  # Older releases expose one mapping per process and bind to loopback by default.
  pids=()
  cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  }
  trap cleanup EXIT INT TERM
  iproxy 50888 50888 "$udid" & pids+=("$!")
  iproxy 50889 50889 "$udid" & pids+=("$!")
  iproxy 50890 50890 "$udid" & pids+=("$!")
  while true; do
    for pid in "${pids[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        set +e
        wait "$pid"
        result=$?
        set -e
        exit "$result"
      fi
    done
    sleep 1
  done
else
  echo "Unrecognized iproxy syntax. Review 'iproxy --help' before forwarding." >&2
  exit 2
fi
