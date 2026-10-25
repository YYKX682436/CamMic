#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
legacy_revision="e2f5ee6de115abdfb48ea000fee86db6995bf724"
fixture_root="$repo_root/.build/cammic-upgrade-fixture"
worktree="$fixture_root/source"
destination="$fixture_root/CamMic-Installer-0.3.1.pkg"
cd "$repo_root"

[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
    echo "Commit source changes before building an upgrade fixture." >&2
    exit 1
}
git cat-file -e "$legacy_revision^{commit}"
mkdir -p "$fixture_root"
if git worktree list --porcelain | grep -Fqx "worktree $worktree"; then
    git worktree remove --force "$worktree"
fi
git worktree add --detach "$worktree" "$legacy_revision"
cleanup() {
    cd "$repo_root"
    git worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "$worktree"
./scripts/build-audio-driver.sh
./scripts/build-source-bundle.sh
./scripts/build-mac-app.sh
./scripts/build-installer-package.sh

legacy_app="$worktree/dist/CamMic.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$legacy_app")" == "0.3.1" ]]
mkdir -p "$(dirname "$destination")"
cp "$worktree/dist/CamMic-Installer.pkg" "$destination"
echo "Built genuine CamMic 0.3.1 upgrade fixture: $destination"
