#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo_root/dist/macos/smoke}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
data_root="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-smoke.XXXXXX")"
trap 'rm -rf "$data_root"' EXIT
"$repo_root/dist/macos/QNotch.app/Contents/MacOS/QNotch" --smoke-test --data-dir "$data_root" --output "$output" &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true; rm -rf "$data_root"' EXIT
# Bound the native app test without requiring GNU timeout on macOS.
for ((attempt=0; attempt<60; attempt++)); do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        wait "$app_pid"
        test "$(tail -n 1 "$output/smoke.txt")" = done
        cat "$output/smoke.txt"
        exit 0
    fi
    sleep 1
done
echo 'Native smoke test timed out' >&2
exit 1
