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
  # Current libusbmuxd syntax; explicitly select USB and bind only to loopback.
  exec iproxy --local --udid "$udid" --source 127.0.0.1 50888:50888
elif [[ "$help_text" == *"LOCAL_TCP_PORT DEVICE_TCP_PORT"* ]]; then
  # Legacy libusbmuxd syntax defaults to USB and binds to loopback.
  exec iproxy 50888 50888 "$udid"
else
  echo "Unrecognized iproxy syntax. Review 'iproxy --help' before forwarding." >&2
  exit 2
fi
