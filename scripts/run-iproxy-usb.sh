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
if [[ "$help_text" == *"LOCAL_PORT:DEVICE_PORT"* && "$help_text" == *"--local"* && "$help_text" == *"--source"* ]]; then
  # Explicitly select USB and keep every Mac-side forwarding socket on loopback.
  exec iproxy --local --udid "$udid" --source 127.0.0.1 \
    50888:50888 50889:50889 50890:50890
else
  echo "This probe requires iproxy with --local and --source. Refusing an unverified USB selection or bind address; update libusbmuxd." >&2
  exit 2
fi
