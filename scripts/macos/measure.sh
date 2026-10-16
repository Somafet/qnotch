#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo_root/dist/macos/measure}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
data_root="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-measure.XXXXXX")"
trap 'rm -rf "$data_root"' EXIT
"$repo_root/dist/macos/QNotch.app/Contents/MacOS/QNotch" --measure --data-dir "$data_root" --output "$output"
cat "$output/performance.json"
