#!/bin/bash
# Sourced by build/test: select full Xcode for this process only, never xcode-select --switch.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    selected_developer="$(xcode-select -p)"
    if [[ "$selected_developer" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
if [[ ! -d "${DEVELOPER_DIR:-$(xcode-select -p)}/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
    echo 'Full Xcode 15+ is required. Set DEVELOPER_DIR to its Contents/Developer directory.' >&2
    exit 1
fi
