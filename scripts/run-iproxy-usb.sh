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
  if ! command -v idevicepair >/dev/null 2>&1; then
    echo "idevicepair is missing. Install libimobiledevice to validate existing system trust before forwarding." >&2
    exit 127
  fi
  if ! idevicepair --udid "$udid" validate >/dev/null 2>&1; then
    echo "Existing device trust could not be validated. Unlock the iPhone and complete Apple's Trust flow in Finder before retrying." >&2
    exit 1
  fi
  # Explicitly select USB and keep every Mac-side forwarding socket on loopback.
  exec iproxy --local --udid "$udid" --source 127.0.0.1 \
    50888:50888 50889:50889 50890:50890
else
  echo "This probe requires iproxy with --local and --source. Refusing an unverified USB selection or bind address; update libusbmuxd." >&2
  exit 2
fi
