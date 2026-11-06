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

## winget, Scoop and Chocolatey

After a Windows release is public, the release workflow's separate `package-managers` job points winget (`Somafet.QNotch`), Scoop (`qnotch` in the `Somafet/scoop-bucket` bucket) and Chocolatey (`qnotch` on the community repository) at its `QNotch-self-contained.zip`. All three install that file unchanged, so nothing about the release assets, their names or the latest endpoint changes. `scripts/package-managers.mjs` writes the manifests from GitHub's metadata for the tag: download address, SHA-256 digest and publication date. It refuses a draft, a ZIP that is not fully uploaded, and any tag that is not the current global latest, so rerunning an old tag's job cannot downgrade users.

- **winget:** the job submits the manifests with Microsoft's `wingetcreate submit`, which opens a pull request on `microsoft/winget-pkgs` from a fork in the token owner's account. The package is a portable ZIP: winget extracts `QNotch.exe` into its package folder and adds the `qnotch` command. Microsoft's validation and review take from a few hours to a few days; the new version is available to users only after the pull request merges.
- **Scoop:** the job commits `bucket/qnotch.json` to the bucket repository. Users get it on their next `scoop update`. The manifest adds the `qnotch` shim and a Start menu shortcut.
- **Chocolatey:** the job packs `qnotch.nuspec` and its install scripts with `choco pack` and pushes the package to the community repository. The install script downloads the ZIP, checks its SHA-256 and extracts `QNotch.exe` into the package folder, which Chocolatey shims as `qnotch`; it also adds a Start menu shortcut for all users. Upgrades and uninstalls first stop a QNotch running from that folder, and uninstalling removes the shortcut. Every version goes through Chocolatey's automated checks and the first one through human moderation, which can take days to weeks; users see a version only once it is approved. A rerun that finds the version already pushed only warns.

Each step skips with a warning while its token is missing, so a release never fails because of a package manager. If a step fails, rerun only that job; the release is already public. To set the jobs up once:

1. Create the public `Somafet/scoop-bucket` repository with a `bucket/` folder, and add the repository secret `SCOOP_BUCKET_TOKEN`: a fine-grained token with Contents read and write on that repository only.
2. Add the repository secret `WINGET_TOKEN`: a classic token with the `public_repo` scope, as `wingetcreate` requires. The first submission creates the package; later ones add versions.
3. Add the repository secret `CHOCOLATEY_API_KEY`: the API key of the community repository account that will maintain `qnotch`. The first push registers the package ID to that account.

To produce the manifests locally for a published release: `node scripts/package-managers.mjs --tag v0.8.4 --out dist/package-managers`, then `winget validate --manifest dist/package-managers/winget`, `scoop install dist/package-managers/scoop/bucket/qnotch.json`, or `choco pack dist/package-managers/chocolatey/qnotch.nuspec --outputdirectory dist/package-managers` followed by `choco install qnotch --source dist/package-managers` from an elevated terminal. None of these publishes anything.

Copies installed this way can still update themselves from Settings, About; the package manager then reports the old version until its own update runs, which downloads the same file again. Chocolatey's package folder is writable only by administrators, so there the in-app update reports that it cannot write to the install folder; update with `choco upgrade qnotch` instead. The website offers each channel only once it is live (see [website/README.md](../website/README.md)).

## Microsoft Store

The Store sells QNotch as a paid MSIX package (product `9MTFK5R4799F`). It is the same self-contained `QNotch.exe`, and it never touches the GitHub release: no new release asset, no change to the ZIP or the latest endpoint. `src/QNotch/Packaging/Build-Msix.ps1` stages the exe with `AppxManifest.xml` and logos drawn by `Assets/Build-AppIcon.ps1`, indexes them with `makepri` and packs `dist/QNotch.msix` with `makeappx`, both from the Windows SDK. The package is unsigned, because the Store signs it on upload. The manifest's identity (`Somafet.QNotch`, its publisher CN and the `Somafet` display name) comes from Partner Center, QNotch, Product identity, and must match it exactly.

After publishing, the release job runs `Build-Msix.ps1 -SkipPublish` on the verified self-contained exe and keeps `dist/QNotch.msix` as the `QNotch-msix` workflow artifact. To ship it, download that artifact, open a new submission in Partner Center, replace the package under Packages and submit. The Store needs a higher version each time, and every tag already gives one (`X.Y.Z.0`).

To try a package locally, turn on Developer Mode and run `pwsh src/QNotch/Packaging/Build-Msix.ps1 -Version 0.9.0 -Register`. Windows registers the staged folder with package identity, so Settings, About shows the Store updates row, `qnotch` works from any terminal, and Start with Windows uses the startup task. Remove it with `Get-AppxPackage Somafet.QNotch | Remove-AppxPackage`. What changes inside the package is described in the [Windows guide](windows/README.md#microsoft-store-copy).

## Mac channel

- Tags are `macos-vX.Y.Z`, optionally with `-alpha.N`, `-beta.N`, or `-rc.N`. Versions can differ from Windows; only suffixed tags are prereleases.
- Assets are `QNotch-macos-arm64.dmg`, `QNotch-macos-x64.dmg`, or `QNotch-macos-universal.dmg`, with `.zip` as an alternative. Ship only architectures actually supported and tested; today that is `QNotch-macos-arm64.dmg` for first installs and `QNotch-macos-arm64.zip`, the same stapled app, as the Sparkle update.
- Pushing a `macos-v*` tag runs `.github/workflows/release-macos.yml` on an Apple silicon runner. It validates the tag, runs repository checks, builds with the tag's version (`CFBundleVersion` is the workflow run number), runs the Mac regressions and UI smoke test, imports the Developer ID certificate into a temporary keychain, then runs `scripts/macos/release.sh`: hardened-runtime signing with `src/QNotch.Mac/QNotch.entitlements`, notarization and stapling of the app, then of the signed disk image, and Gatekeeper assessment of both. It publishes through the same guarded publisher with `--platform macos`, which derives `--latest=false` from the channel and offers no override, including for stable Mac releases. It shares the `qnotch-release` concurrency group with Windows. The Windows tag workflow does not run on `macos-v*`.
- Resolve Mac downloads from the Mac channel rather than `/releases/latest`. Updates use a separate Sparkle appcast (below). Do not use global latest as a platform feed.

The workflow reads the repository variable `APPLE_TEAM_ID` (and optionally `MACOS_SIGNING_IDENTITY`) and the secrets `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and, for updates, `SPARKLE_PRIVATE_KEY` (set with `bash scripts/macos/setup-sparkle.sh`). Set them once with `bash scripts/macos/setup-signing.sh` on the Mac that holds the certificate; it checks that the `.p12` contains a Developer ID Application identity with its private key for the chosen team and that Apple accepts the API key before uploading anything. Account names and credential values do not belong in documentation or issues.

To produce the same signed disk image locally, save the API key as a notarytool profile (the setup script offers to), then run `scripts/macos/build.sh` and `APPLE_TEAM_ID=<team> NOTARY_KEYCHAIN_PROFILE=qnotch bash scripts/macos/release.sh`. That submits to Apple's notary service but publishes nothing.

Before the first public Mac release, verify installation of the published disk image on a clean Mac and on macOS 13, the deployment target.

## Mac updates (Sparkle)

Installed copies use [Sparkle 2](https://sparkle-project.org). They read `https://raw.githubusercontent.com/Somafet/qnotch/macos-appcast/appcast.xml` (`UpdateChannel.feedURL`), an RSS feed on the `macos-appcast` branch, which holds nothing else and is written only by the release workflow. The host is not trusted: the app's `SUPublicEDKey` must verify the feed (`SURequireSignedFeed`) and each update before extraction (`SUVerifyUpdateBeforeExtraction`), and Sparkle installs only a copy signed by the same Developer ID team.

The release workflow, after notarization:

1. `release.sh` signs Sparkle's `Autoupdate`, `Updater.app` and framework inside out before the app (the build removes Sparkle's XPC services, which only sandboxed apps use), and zips the stapled app as `QNotch-macos-arm64.zip`.
2. **Sign the Sparkle update** checks that the `SPARKLE_PRIVATE_KEY` secret belongs to `SUPublicEDKey` (`appcast.mjs check-key`; a mismatch would make every installed copy reject the update), signs the zip with Sparkle's `sign_update` and verifies the signature. Only this step and the appcast job receive the key.
3. The guarded publisher publishes the disk image and the zip.
4. The separate `appcast` job runs `scripts/macos/publish-appcast.sh`: it checks that GitHub serves the published zip with the signed length, adds an item (newest first, at most 30) with `sparkle:version` = the workflow run number (`CFBundleVersion`), the tag's short version, macOS 13 and arm64 requirements, the release notes as Markdown and a link to the release, signs the whole feed, verifies it, and pushes the branch. Prerelease tags go to Sparkle's `beta` channel, which only copies with **Beta versions** on read. Rerunning the job for the same tag replaces its item. If it fails, rerun only that job; the release is already public.

Sparkle compares `CFBundleVersion`, the run number, so a later stable release always supersedes an earlier beta. A beta tagged after a stable release with a lower marketing version would also be offered to beta users; tag versions in order.

The signing key lives in the login keychain of the release Mac (`generate_keys --account qnotch`, from `src/QNotch.Mac/.build/artifacts/sparkle/Sparkle/bin` after a build). `bash scripts/macos/setup-sparkle.sh` checks it against `SUPublicEDKey` and uploads it as `SPARKLE_PRIVATE_KEY`. Back it up (`src/QNotch.Mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account qnotch -x <file>`) somewhere safe: without it, installed copies can never be updated again except by a manual download of a build with a new key.

## Required checks

The CI workflow runs on every pull request and every push to `main`, without top-level path filters:

- `changes`: on pull requests, lists the changed files and decides with [scripts/ci-platforms.mjs](../scripts/ci-platforms.mjs) whether `windows` and `macos` must run. Pushes to `main` always run both.
- `windows`: existing warning-free .NET build, updater tests, phone-sharing tests, and isolated snapshot smoke test. Snapshot artifacts retain the name `snapshots`.
- `macos`: real Apple silicon Swift/AppKit release build without signing credentials, XCTest regressions, and isolated native UI smoke checks with PNG artifacts named `macos-smoke`.
- `repository`: Node.js 24+, `npm ci`, and `npm test` at the root, followed by pinned actionlint in Docker on the Linux runner. One development dependency parses workflow/issue YAML; it is not an app runtime dependency. Checks cover release channels, upload/promotion failure paths, workflow ordering, documentation links, and forms.
- `website`: its own Node.js 24+ install and static Astro build under `website/`. Its lockfile and dependencies are separate from repository tooling.
- `build`: the existing required branch-protection check. It always evaluates after the jobs above and succeeds only if all succeeded, except that it accepts a skipped `windows` or `macos` job when `changes` decided that platform is unaffected. A failed or cancelled job, or a skip that `changes` did not choose, cannot silently turn it green.

A pull request runs a platform job only when it changes that platform's files or anything shared; [CONTRIBUTING.md](../CONTRIBUTING.md#build-and-check-your-change) lists the paths. Unknown paths run both. Contributors can run only their affected local checks; CI verifies every affected platform. The real Mac validation job is included in both the aggregate dependencies and success gate, with workflow contract tests. Do not rename the required `build` check or replace platform validation with empty jobs.

Repository label definitions live in [.github/labels.yml](../.github/labels.yml). They are a small managed subset; unrelated existing labels should be preserved. Updating that file does not itself change GitHub labels.

References: [GitHub release creation](https://cli.github.com/manual/gh_release_create), [release editing](https://cli.github.com/manual/gh_release_edit), and [job conditions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions).
