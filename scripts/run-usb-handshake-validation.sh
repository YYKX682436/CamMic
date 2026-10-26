#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$repo_root/.build/usb-handshake-validation"
mkdir -p "$build_dir"
swiftc -O -parse-as-library \
  "$repo_root/Shared/CamMicProtocol.swift" \
  "$repo_root/scripts/usb-handshake-validation.swift" \
  -o "$build_dir/cammic-usb-handshake-validation"
exec "$build_dir/cammic-usb-handshake-validation" "$@"
