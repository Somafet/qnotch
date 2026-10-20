#!/bin/bash
# Usage: snapshot.sh [dir] [--only <patterns>] [--appearance light|dark]
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="$repo_root/dist/macos/snapshots"
if [[ $# -gt 0 && $1 != --* ]]; then output="$1"; shift; fi
mkdir -p "$output"
output="$(cd "$output" && pwd)"
# Only the kinds of files a run writes, so stale views do not fail the checker.
find "$output" -maxdepth 1 -type f \( -name '*.png' -o -name '*.txt' -o -name '*.log' \) -delete
# Render only: no windows on screen, a fresh temporary data root deleted on exit.
"$repo_root/dist/macos/QNotch.app/Contents/MacOS/QNotch" --snapshot "$output" "$@" &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true' EXIT
# Bound the run without requiring GNU timeout on macOS.
for ((attempt=0; attempt<300; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        status=0
        wait "$app_pid" || status=$?
        cat "$output/snapshot.txt"
        test "$status" = 0
        test "$(tail -n 1 "$output/snapshot.txt")" = done
        exit 0
    fi
    sleep 0.2
done
echo 'Snapshot run timed out' >&2
exit 1
