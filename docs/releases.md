# Releases and CI

QNotch has one repository and independent platform channels. Windows is available; macOS has a native development target and no public download yet. Preserve the compatibility contract below for already-installed Windows versions.

## Windows compatibility contract

- Stable tags remain `vX.Y.Z`, such as `v0.4.1`. Do not rename them to `windows-v*`.
- GitHub's global latest stable release belongs to Windows. Existing clients call `https://api.github.com/repos/Somafet/qnotch/releases/latest`; the website also links to the global latest release.
- Every Windows release includes exactly `QNotch.exe` and `QNotch-self-contained.zip`. Keep these public names, even if local build directories change later.
- The ZIP contains exactly one root entry, `QNotch.exe`. No parent folder, README, signature sidecar, or additional file belongs inside it.
- Both executables are Windows x64, carry the tag's version, and retain their runtime variant. Publish profiles keep their ReadyToRun, intermediate, and bundle output directories separate.
- Uploaded assets must be at most 256 MiB each and expose an uploaded state, positive size, exact repository download URL, and matching GitHub SHA-256 digest. The installed updater validates these and rejects invalid packages.
- Keep repository URL, endpoint, version parsing, checksum, archive, and executable validation compatible. Migration of installed clients is separate work.

Do not add Mac-only assets under a Windows version tag or mark a Mac release as latest. Prefixing Mac tags helps clients ignore them but does not make the global latest endpoint platform-aware.

## Publishing Windows

Push a stable `vX.Y.Z` tag to the official repository. The Windows release workflow:

1. Validates the tag using `scripts/release-policy.mjs` before publishing binaries.
2. Runs repository checks, builds Windows without warnings, and runs updater and phone-sharing regressions.
3. Publishes both runtime variants using the tag version and builds the legacy single-exe ZIP.
4. Runs `--verify-publish` to inspect both embedded runtime configurations and the ZIP's exact contents.
5. Calls `scripts/publish-release.mjs` to create a draft, upload files, compare their local SHA-256 hashes/sizes/URLs with GitHub metadata, and publish only after verification. Only this step receives the release token.

The publisher explicitly creates drafts with `--latest=false`, then promotes a verified Windows release with `--latest=true`. It refuses the same or an older version than global latest, a global latest tag from another platform, invalid assets, non-404 API failures, or changes to a published release. It rechecks latest before promotion. Generated Windows notes start from the previous Windows latest tag so interleaved Mac tags do not determine that range.

An interrupted upload leaves a draft. Rerunning the failed workflow can replace assets in that draft and verify them again; it never overwrites a published release. If the draft contains unexpected extra assets or inconsistent metadata, inspect and correct the draft before retrying. Do not bypass the guard by manually publishing an incomplete draft.

All platform release workflows must share concurrency group `qnotch-release` with cancellation disabled. This serializes publication instead of cancelling an upload halfway through. The workflow and publisher refuse official publication from forks.

The underlying command, after all local build/package checks, is:

```powershell
node scripts/publish-release.mjs --platform windows --tag v0.4.1 --asset dist/QNotch.exe --asset dist/QNotch-self-contained.zip
```

This command publishes remotely. Repository tests use a fake GitHub CLI transport and never create releases. Normal development does not require running the publishing command.

## Future Mac channel

- Use `macos-vX.Y.Z`, optionally with `-alpha.N`, `-beta.N`, or `-rc.N`. Versions can differ from Windows; only suffixed tags are prereleases.
- Use `QNotch-macos-arm64.dmg`, `QNotch-macos-x64.dmg`, or `QNotch-macos-universal.dmg`, with `.zip` as an alternative. Ship only architectures actually supported and tested.
- Use the same guarded publisher with `--platform macos`. It derives `--latest=false` from the channel and offers no override, including for stable Mac releases. The current Windows tag workflow does not run on `macos-v*`.
- Resolve Mac downloads from the Mac channel rather than `/releases/latest`. If Sparkle is adopted, provide a separate appcast and its signed updates. Do not use global latest as a platform feed.
- Add signing, notarization, stapling where applicable, and clean-machine installation verification with the actual Mac release workflow. Configure identity and credentials privately in release secrets. Account names and credential values do not belong in documentation or issues.

Do not publish a Mac release until a real app target, supported-platform documentation, signing/installation verification, and CI exist. The repository policy supports its future publication; it does not certify a Mac binary or an update feed today.

## Required checks

The CI workflow runs on every pull request and every push to `main`, without top-level path filters:

- `windows`: existing warning-free .NET build, updater tests, phone-sharing tests, and isolated snapshot smoke test. Snapshot artifacts retain the name `snapshots`.
- `macos`: real Apple silicon Swift/AppKit release build without signing credentials, XCTest regressions, and isolated native UI smoke checks with PNG artifacts named `macos-smoke`.
- `repository`: Node.js 24+, `npm ci`, and `npm test` at the root, followed by pinned actionlint in Docker on the Linux runner. One development dependency parses workflow/issue YAML; it is not an app runtime dependency. Checks cover release channels, upload/promotion failure paths, workflow ordering, documentation links, and forms.
- `website`: its own Node.js 24+ install and static Astro build under `website/`. Its lockfile and dependencies are separate from repository tooling.
- `build`: the existing required branch-protection check. It always evaluates after the jobs above and succeeds only if all succeeded. A failed, cancelled, or skipped dependency cannot silently turn it green.

The Windows job intentionally runs even for documentation and website pull requests for now. This keeps the existing protection reliable without introducing change-detection logic. Contributors can run only their affected local checks; CI verifies the full repository. The real Mac validation job is included in both the aggregate dependencies and success gate, with workflow contract tests. Do not rename the required `build` check or replace platform validation with empty jobs.

Repository label definitions live in [.github/labels.yml](../.github/labels.yml). They are a small managed subset; unrelated existing labels should be preserved. Updating that file does not itself change GitHub labels.

References: [GitHub release creation](https://cli.github.com/manual/gh_release_create), [release editing](https://cli.github.com/manual/gh_release_edit), and [job conditions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions).
