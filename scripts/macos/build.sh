#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/macos/toolchain.sh"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'This milestone supports building and running on Apple silicon macOS only.' >&2
    exit 1
fi
package="$repo_root/src/QNotch.Mac"
xcrun swift build --package-path "$package" -c release --arch arm64 -Xswiftc -warnings-as-errors
binary_dir="$(xcrun swift build --package-path "$package" -c release --arch arm64 --show-bin-path)"
app="$repo_root/dist/macos/QNotch.app"
mkdir -p "$app/Contents/MacOS"
# Replace the inode atomically: overwriting a mapped, ad hoc signed Mach-O can invalidate
# the kernel's cached signature and kill a subsequent launch while an old instance runs.
temporary_executable="$(mktemp "$app/Contents/MacOS/.QNotch.XXXXXX")"
cp "$binary_dir/QNotch" "$temporary_executable"
chmod +x "$temporary_executable"
mv -f "$temporary_executable" "$app/Contents/MacOS/QNotch"
# Sparkle (updates). QNotch is not sandboxed, so Sparkle's XPC services are unused and removed;
# release.sh signs what remains (Autoupdate, Updater.app, the framework) inside out.
frameworks="$app/Contents/Frameworks"
rm -rf "$frameworks"
mkdir -p "$frameworks"
ditto "$binary_dir/Sparkle.framework" "$frameworks/Sparkle.framework"
rm -rf "$frameworks/Sparkle.framework/Versions/B/XPCServices" "$frameworks/Sparkle.framework/XPCServices"
cp "$package/Info.plist" "$app/Contents/Info.plist"
# The release workflow passes the tag's version and a monotonic build number.
if [[ -n "${QNOTCH_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $QNOTCH_VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${QNOTCH_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $QNOTCH_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
# The yr.no weather symbols (github.com/metno/weathericons, MIT), the same files Windows ships.
icons="$app/Contents/Resources/WeatherIcons"
rm -rf "$icons"
mkdir -p "$icons"
cp "$repo_root/src/QNotch/Modules/Weather/Icons/"*.png "$repo_root/src/QNotch/Modules/Weather/Icons/LICENSE" "$icons/"
/usr/libexec/PlistBuddy -c "Add :QNotchSourceRevision string $(git -C "$repo_root" rev-parse HEAD)" "$app/Contents/Info.plist"
source_dirty=false
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then source_dirty=true; fi
/usr/libexec/PlistBuddy -c "Add :QNotchSourceDirty bool $source_dirty" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
# No Developer ID, provisioning profile, signing secret, or publication in development builds.
echo "Built $app"
