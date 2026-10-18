#!/bin/bash
# Run once on the Mac whose login keychain holds QNotch's Sparkle signing key (generate_keys
# --account qnotch) to give the Mac release workflow the SPARKLE_PRIVATE_KEY secret. Checks the
# key against Info.plist's SUPublicEDKey first. Nothing is printed. Never enable tracing.
set +x
set -euo pipefail
umask 077
repo=Somafet/qnotch
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/macos/toolchain.sh"
command -v gh >/dev/null || { echo 'Install GitHub CLI: brew install gh; then gh auth login' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Run gh auth login first.' >&2; exit 1; }
tools="$repo_root/src/QNotch.Mac/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/generate_keys" ]] || xcrun swift package --package-path "$repo_root/src/QNotch.Mac" resolve

scratch="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-sparkle.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# macOS may ask once whether generate_keys may read the key.
"$tools/generate_keys" --account qnotch -x "$scratch/key" >/dev/null
SPARKLE_PRIVATE_KEY="$(cat "$scratch/key")" node "$repo_root/scripts/macos/appcast.mjs" check-key --plist "$repo_root/src/QNotch.Mac/Info.plist"
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" < "$scratch/key"
echo "Uploaded SPARKLE_PRIVATE_KEY to $repo. Keep a backup of the key: generate_keys --account qnotch -x <file>."
