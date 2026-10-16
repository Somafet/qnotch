# Agent instructions

Read [ARCHITECTURE.md](ARCHITECTURE.md) for shared principles and the Windows implementation contract. See [CONTRIBUTING.md](CONTRIBUTING.md) for checks by area and [docs/releases.md](docs/releases.md) before changing packaging or publishing.

## Work by platform

- Windows app: `src/QNotch/`, `tests/QNotch.UpdateTests/`, and `tests/QNotch.PhoneShareTests/`. Follow [the Windows agent instructions](src/QNotch/AGENTS.md), including the publish and Explorer-launch rules, for work in any of these paths or on Windows packaging.
- macOS: native Swift/AppKit implementation in `src/QNotch.Mac/`. Read [the macOS guide](docs/macos/README.md) for build, test, smoke, and launch commands. Do not claim feature parity or require Windows tooling for Mac-only work.
- Website: `website/`. Follow [website/README.md](website/README.md) and run its static build.
- Repository tooling: `scripts/`, `tests/repository/`, and `.github/`. Run `npm ci` and `npm test` from the root with Node.js 24 or newer. Workflow changes must preserve the required `build` check and existing Windows release compatibility.

Do not move the Windows app, rename its downloads, change the latest-release endpoint, or change the contents of its single-exe ZIP as part of repository preparation. A Mac release must never replace the global Windows latest release. Use the guarded publisher documented in the release guide.

## Scope and verification

Keep common product contracts separate from OS implementations. Prefer shared examples and fixtures over a speculative shared runtime. The Mac port uses Swift/AppKit and native controls, with platform-local module contracts.

Run checks for each affected area. Windows features must leave a freshly published `dist/QNotch.exe` for the user to try. Mac-only and website-only changes do not require a Windows build. Shared behavior or release changes require the affected Windows regression checks too.

Keep personal account details and signing credentials out of public issues, documentation, logs, and source. Describe signing requirements generically; configure the actual identity privately.
