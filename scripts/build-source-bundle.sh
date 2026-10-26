#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    echo "Commit all source and icon changes before creating the corresponding source archive." >&2
    exit 1
fi
source_revision="$(git rev-parse HEAD)"
short_revision="${source_revision:0:12}"
dist="$repo_root/dist"
mkdir -p "$dist"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/cammic-source.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/CamMic-$short_revision"
git archive --format=tar --exclude='TestFixtures/CamMic-Installer-0.3.2-902f1a9.pkg' \
  --prefix="CamMic-$short_revision/" "$source_revision" | tar -xf - -C "$temporary"
tar -czf "$dist/CamMic-Source-$short_revision.tar.gz" -C "$temporary" "CamMic-$short_revision"

echo "Source revision: $source_revision"
echo "Source archive: $dist/CamMic-Source-$short_revision.tar.gz"
shasum -a 256 "$dist/CamMic-Source-$short_revision.tar.gz"
