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

## Features on both platforms

Windows and macOS are built separately, so behaviour and wording drift unless both builds follow one written contract. [UI conventions](spec/ui-conventions.md) sorts every difference into product contract (must match), platform look (follow the platform) and platform capability (record it).

- **Contract first.** Before either platform implements a feature or UI change that both will have, write the contract in `spec/`: a new file or a section of an existing one, such as [Settings](spec/settings.md). It covers:
  - the exact wording, per state or mode, using the platform terms;
  - which controls exist, their order, and where actions sit;
  - when each control shows, hides or is disabled;
  - the identifiers that checks use;
  - any allowed differences.

  Give both implementations the same contract. Don't let each one interpret a loose description on its own.
- **Follow the shared patterns.** Check the patterns in UI conventions (caption strips, link buttons, action placement, hiding options that don't apply) before you invent a new style. If a platform needs a new pattern, add it there.
- **Change the contract with the code.** When you change shared wording or behaviour on one platform, update the spec in the same PR. Either make the matching change on the other platform, or add the difference to the spec's known gaps.
- **Pair the PRs.** A platform PR for a shared feature links its counterpart PR, or says it is platform-only and why. Review both diffs side by side against the contract. Anything that differs, and is not a platform term or a listed deliberate difference, is a bug.
- **Orchestrating two sessions.** When one agent coordinates a Windows session and a Mac session, it writes the contract before starting either. Both briefs quote it. The coordinator then compares the two results against it.
