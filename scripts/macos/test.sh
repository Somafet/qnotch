#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/macos/toolchain.sh"
xcrun swift test --package-path "$repo_root/src/QNotch.Mac" -c release --arch arm64 -Xswiftc -warnings-as-errors
