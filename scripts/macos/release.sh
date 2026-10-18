#!/bin/bash
# Signs dist/macos/QNotch.app with Developer ID, notarizes and staples it, and packages
# dist/macos/QNotch-macos-arm64.dmg (also signed, notarized and stapled) and the Sparkle update
# dist/macos/QNotch-macos-arm64.zip. Run build.sh first. The update's EdDSA signature is added
# by the release workflow; this script needs no Sparkle key.
#
# APPLE_TEAM_ID selects the Developer ID Application identity for that team from your keychains
# (MACOS_SIGNING_IDENTITY overrides it). Notarization credentials, one of:
#   NOTARY_KEYCHAIN_PROFILE  a profile saved with `xcrun notarytool store-credentials` (local)
#   APP_STORE_CONNECT_KEY_PATH, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID (CI)
# Never enable shell tracing here.
set +x
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_root/scripts/macos/toolchain.sh"
team_id="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the team that signs QNotch}"
identity="${MACOS_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | grep -F 'Developer ID Application:' | grep -F "($team_id)" \
        | head -n 1 | sed -E 's/^[^"]*"(.*)"$/\1/' || true)"
    [[ -n "$identity" ]] || { echo "No Developer ID Application identity for team $team_id in your keychains." >&2; exit 1; }
fi
app="$repo_root/dist/macos/QNotch.app"
dmg="$repo_root/dist/macos/QNotch-macos-arm64.dmg"
update="$repo_root/dist/macos/QNotch-macos-arm64.zip"
entitlements="$repo_root/src/QNotch.Mac/QNotch.entitlements"
[[ -d "$app" ]] || { echo "Run scripts/macos/build.sh first: $app is missing." >&2; exit 1; }
[[ "$identity" == *"($team_id)" ]] || { echo "Signing identity is not on team $team_id." >&2; exit 1; }

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    notary_auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    : "${APP_STORE_CONNECT_KEY_PATH:?Set NOTARY_KEYCHAIN_PROFILE or the App Store Connect key variables}"
    : "${APP_STORE_CONNECT_KEY_ID:?APP_STORE_CONNECT_KEY_ID is missing}"
    : "${APP_STORE_CONNECT_ISSUER_ID:?APP_STORE_CONNECT_ISSUER_ID is missing}"
    notary_auth=(--key "$APP_STORE_CONNECT_KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-release.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

notarize() {
    local submission="$1" report="$scratch/notary.json"
    echo "Notarizing $(basename "$submission")"
    if ! xcrun notarytool submit "$submission" "${notary_auth[@]}" --wait --timeout 30m --output-format json > "$report"; then
        cat "$report" >&2 || true
        exit 1
    fi
    local id status
    id="$(plutil -extract id raw -o - "$report")"
    status="$(plutil -extract status raw -o - "$report")"
    if [[ "$status" != Accepted ]]; then
        echo "Notarization $id finished as $status:" >&2
        xcrun notarytool log "$id" "${notary_auth[@]}" >&2 || true
        exit 1
    fi
    echo "Notarization $id accepted"
}

# 1. Sparkle's helpers, inside out, then the app: hardened runtime, secure timestamp, Now playing's
#    Apple Events entitlement. Under the hardened runtime the app only loads its own team's code.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$sparkle" ]] || { echo "Sparkle.framework is missing from $app." >&2; exit 1; }
for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --sign "$identity" --options runtime --timestamp "$nested"
done
codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
signed_team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$signed_team" == "$team_id" ]] || { echo "App was signed by team '$signed_team', expected $team_id." >&2; exit 1; }

# 2. Notarize and staple the app itself, so a copy dragged out of the disk image passes
#    Gatekeeper offline too.
ditto -c -k --keepParent "$app" "$scratch/QNotch.zip"
notarize "$scratch/QNotch.zip"
xcrun stapler staple "$app"

# 3. The Sparkle update: the stapled app, zipped the way Sparkle extracts it.
rm -f "$update"
ditto -c -k --sequesterRsrc --keepParent "$app" "$update"

# 4. The disk image: the stapled app and an Applications shortcut.
stage="$scratch/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/QNotch.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname QNotch -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

# 5. Check what a downloading user's Mac will check.
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl --assess --type execute --verbose=2 "$app"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
echo "Signed, notarized and stapled $dmg and $update"
