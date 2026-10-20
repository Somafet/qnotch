#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo_root/dist/macos/measure}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
# The app uses a fresh temporary data root and deletes it on exit; exit 1 when a limit fails.
status=0
"$repo_root/dist/macos/QNotch.app/Contents/MacOS/QNotch" --measure "$output" || status=$?
cat "$output/performance.json"
exit "$status"
