#!/bin/bash
# Run once on your Mac to give the Mac release workflow its signing and notarization
# credentials. Values go straight from your files into encrypted Actions secrets of
# Somafet/qnotch; nothing is printed or written to the repository. Never enable tracing.
set +x
set -euo pipefail
umask 077

repo=Somafet/qnotch
identity_prefix='Developer ID Application:'
[[ "$(uname -s)" == Darwin ]] || { echo 'Run this on your Mac.' >&2; exit 1; }
command -v gh >/dev/null || { echo 'Install GitHub CLI: brew install gh; then gh auth login' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo 'Run gh auth login first.' >&2; exit 1; }
gh repo view "$repo" --json nameWithOwner >/dev/null

scratch="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-signing.XXXXXX")"
keychain="$scratch/check.keychain-db"
cleanup() { security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT

read_path() {
    local label="$1" default="${2:-}" answer
    read -r -p "$label${default:+ [$default]}: " answer
    answer="${answer:-$default}"
    answer="${answer/#\~/$HOME}"
    [[ -f "$answer" ]] || { echo "File does not exist: $answer" >&2; exit 1; }
    selected="$answer"
}

read -r -p 'Apple team ID that signs QNotch: ' team_id
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || { echo 'A team ID is 10 letters and digits.' >&2; exit 1; }
echo "This uploads QNotch's Mac signing credentials to $repo for team $team_id."
echo "Export that team's Developer ID Application certificate from Keychain Access"
echo '(My Certificates, right-click, Export) as a .p12 with a new password first.'
echo

# 1. Developer ID certificate. Import it into a throwaway keychain to prove that it holds the
#    private key and belongs to the chosen team, not another team's certificate.
read_path 'Developer ID Application .p12'
p12="$selected"
read -r -s -p 'Password for the .p12: ' p12_password; printf '\n'
security create-keychain -p '' "$keychain" >/dev/null
if ! security import "$p12" -k "$keychain" -P "$p12_password" -T /usr/bin/codesign >/dev/null 2>&1; then
    echo 'The .p12 could not be opened. Check the password.' >&2; exit 1
fi
if ! security find-identity -v -p codesigning "$keychain" | grep -F "$identity_prefix" | grep -qF "($team_id)"; then
    echo "The .p12 has no valid $identity_prefix identity for team $team_id with its private key." >&2
    echo "It may be another team's certificate, or exported without the private key." >&2
    exit 1
fi
identity="$(security find-identity -v -p codesigning "$keychain" | grep -F "$identity_prefix" | grep -F "($team_id)" | head -n 1 | sed -E 's/^[^"]*"(.*)"$/\1/')"
echo "Certificate OK: $identity"

# 2. App Store Connect API key for notarization (team $team_id, Developer role is enough).
default_key="$(ls "$HOME"/apple/qnotch/AuthKey_*.p8 2>/dev/null | head -n 1 || true)"
read_path 'App Store Connect API key .p8' "$default_key"
p8="$selected"
openssl pkey -in "$p8" -noout 2>/dev/null || { echo 'That .p8 is not a valid private key.' >&2; exit 1; }
default_key_id="$(basename "$p8" .p8)"; default_key_id="${default_key_id#AuthKey_}"
read -r -p "Key ID [$default_key_id]: " key_id; key_id="${key_id:-$default_key_id}"
read -r -p 'Issuer ID (App Store Connect, Users and Access, Integrations): ' issuer_id
[[ "$issuer_id" =~ ^[0-9a-fA-F-]{36}$ ]] || { echo 'The issuer ID should be a UUID.' >&2; exit 1; }

# 3. Prove the key works before uploading it.
if ! xcrun notarytool history --key "$p8" --key-id "$key_id" --issuer "$issuer_id" >/dev/null 2>&1; then
    echo 'Apple rejected the API key, key ID or issuer ID.' >&2; exit 1
fi
echo 'API key OK'

# 4. Upload.
/usr/bin/base64 < "$p12" | tr -d '\r\n' | gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo "$repo"
printf '%s' "$p12_password" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$repo"
/usr/bin/base64 < "$p8" | tr -d '\r\n' | gh secret set APP_STORE_CONNECT_PRIVATE_KEY_BASE64 --repo "$repo"
printf '%s' "$key_id" | gh secret set APP_STORE_CONNECT_KEY_ID --repo "$repo"
printf '%s' "$issuer_id" | gh secret set APP_STORE_CONNECT_ISSUER_ID --repo "$repo"
gh variable set APPLE_TEAM_ID --repo "$repo" --body "$team_id"
gh variable set MACOS_SIGNING_IDENTITY --repo "$repo" --body "$identity"
unset p12_password
echo "Uploaded to $repo."

# 5. Optional: the same key for local release builds (scripts/macos/release.sh).
read -r -p 'Also save it as the local notarytool profile "qnotch"? [Y/n] ' answer
if [[ ! "$answer" =~ ^[Nn] ]]; then
    xcrun notarytool store-credentials qnotch --key "$p8" --key-id "$key_id" --issuer "$issuer_id" >/dev/null
    echo "Saved. Local release: APPLE_TEAM_ID=$team_id NOTARY_KEYCHAIN_PROFILE=qnotch bash scripts/macos/release.sh"
fi
