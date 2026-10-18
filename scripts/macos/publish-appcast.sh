#!/bin/bash
# Adds a published macos-v* release to the Sparkle appcast and pushes it to the macos-appcast
# branch, which installed copies read through UpdateChannel.feedURL. Run by the Mac release
# workflow after the release is public. Rerunning it for the same tag replaces that entry.
#
#   publish-appcast.sh <tag> <build> <signature> <length>
#
# GH_TOKEN pushes the branch; SPARKLE_PRIVATE_KEY signs the feed. Never enable shell tracing.
set +x
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tag="${1:?tag}" build="${2:?build}" signature="${3:?signature}" length="${4:?length}"
: "${GH_TOKEN:?GH_TOKEN is missing}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is missing}"
repository=Somafet/qnotch
branch=macos-appcast
tools="$repo_root/src/QNotch.Mac/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/sign_update" ]] || { echo "Sparkle's sign_update is missing; resolve the Mac package first." >&2; exit 1; }
node "$repo_root/scripts/macos/appcast.mjs" check-key --plist "$repo_root/src/QNotch.Mac/Info.plist"

# The feed may only point at what GitHub actually serves for this release.
published="$(gh api "repos/$repository/releases/tags/$tag" \
    --jq '[.draft, (.assets[] | select(.name == "QNotch-macos-arm64.zip") | .size)] | @tsv')"
[[ "$published" == "false"$'\t'"$length" ]] || { echo "$tag is not published with a $length-byte QNotch-macos-arm64.zip." >&2; exit 1; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/qnotch-appcast.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
remote="https://github.com/$repository.git"
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
git_remote() { git -C "$scratch/feed" -c http.extraheader="$auth" "$@"; }
git init -q "$scratch/feed"
set +e
git_remote ls-remote --exit-code --heads "$remote" "$branch" >/dev/null
exists=$?
set -e
if [[ $exists == 0 ]]; then
    git_remote fetch -q --depth 1 "$remote" "$branch"
    git -C "$scratch/feed" checkout -q -b "$branch" FETCH_HEAD
elif [[ $exists == 2 ]]; then
    echo "Creating the $branch branch"
    git -C "$scratch/feed" checkout -q --orphan "$branch"
else
    echo "Could not read $remote." >&2; exit 1
fi

gh release view "$tag" --repo "$repository" --json body --jq .body > "$scratch/notes.md"
feed="$scratch/feed/appcast.xml"
node "$repo_root/scripts/macos/appcast.mjs" add --feed "$feed" --tag "$tag" --build "$build" \
    --length "$length" --signature "$signature" --notes "$scratch/notes.md"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - "$feed"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$feed"

git -C "$scratch/feed" add appcast.xml
if git -C "$scratch/feed" diff --cached --quiet; then echo 'The appcast is already up to date.'; exit 0; fi
git -C "$scratch/feed" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -q -m "Add $tag to the Mac appcast"
git_remote push -q "$remote" "HEAD:refs/heads/$branch"
echo "Published $tag (build $build) to the $branch appcast."
