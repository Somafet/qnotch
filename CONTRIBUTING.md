# Contributing to QNotch

Bug reports, fixes, documentation, and extensions are welcome. One repository hosts the released Windows app, its website, and a native Mac development milestone. You can contribute to one area without owning both operating systems.

## Before you start

- **Bugs:** include the platform/area, OS and architecture, app version or commit, reproduction steps, and relevant logs. Remove personal details, tokens, and signing/account information.
- **Small fixes:** send a focused pull request directly.
- **New extensions or larger changes:** open an issue describing the behavior and where it appears: card, tab, pill, game bar, settings, or platform integration. Space is limited, so agree on scope first.
- **Mac work:** read [its status and scope](docs/macos/README.md). Its Swift/AppKit target currently supports Apple silicon on macOS 13+; no public download or feature parity is implied.

## Choose an area

- `src/QNotch/` and `tests/QNotch.*Tests/`: Windows C#/WPF implementation and tests. Existing paths and solution stay intact.
- `src/QNotch.Mac/`: native Swift/AppKit shell, platform-local contracts, countdown module, and XCTest regressions.
- `website/`: static Astro landing page and interactive Windows demo.
- `scripts/`, `tests/repository/`, and `.github/`: cross-platform repository checks and publishing policy.
- `spec/` and `tests/fixtures/`: shared behavior and concrete compatibility examples. Avoid speculative shared runtime code.
- `docs/windows/` and `docs/macos/`: platform guides. [ARCHITECTURE.md](ARCHITECTURE.md) retains the Windows module contract and existing anchors.

## Build and check your change

Run the relevant local checks. CI validates the whole repository, including Windows, even when a contributor only has another operating system.

### Windows

Use Windows x64 and the .NET 10 SDK. From the repository root:

```powershell
dotnet build src/QNotch/QNotch.csproj -c Release -warnaserror
dotnet run --project tests/QNotch.UpdateTests -c Release
dotnet run --project tests/QNotch.PhoneShareTests -c Release
dotnet run --project tests/QNotch.OnboardingTests -c Release
```

Follow [Windows development](docs/windows/development.md) for isolated snapshots and publishing. For UI changes, inspect PNGs, check `snapshot.txt` ends in `done`, and attach the changed images. For background changes, measure before/after CPU and memory against the [hard limits](ARCHITECTURE.md#performance-rules-hard), including version, hardware, panel state, and interval. Windows features should leave a fresh `dist/QNotch.exe`; interactive launches go through Explorer.

### macOS

Use Apple silicon and Xcode 15+ (Swift 5.9+). From the repository root:

```sh
bash scripts/macos/build.sh
bash scripts/macos/test.sh
bash scripts/macos/smoke.sh
open dist/macos/QNotch.app
```

See [Mac development](docs/macos/README.md) for toolchain selection, isolated data/log locations, accessibility and snapshot checks, limitations, and performance measurement. Inspect native smoke PNGs after UI changes. Do not require Windows tools for Mac-only work or report unrun checks as passing.

### Website

Use Node.js 24 or newer. Its dependencies are separate from the root tooling:

```sh
cd website
npm ci
npm run build
```

See [website/README.md](website/README.md). Website redesign and platform download UX are separate from repository preparation.

### Repository, shared contracts, and releases

Use Node.js 24 or newer from the root:

```sh
npm ci
npm test
```

These tests run on Windows, macOS, and Linux and never publish a release. They validate release policy/failure paths, CI structure, issue forms, and relative Markdown file links. The YAML parser is a development dependency only.

For release or shared-protocol changes, also run affected Windows regressions. If packaging changes, publish both variants and run `--verify-publish` as described in [Windows development](docs/windows/development.md). Keep tags, asset names, ZIP layout, and the latest endpoint compatible with installed clients. Read [release policy](docs/releases.md) before editing workflows or publishing.

CI's required check remains named `build`. It aggregates `windows`, `macos`, `repository`, and `website`, and rejects failed, cancelled, or skipped dependencies. The Mac job builds the real unsigned app, runs regressions, and validates the native UI.

## Extensions and platform boundaries

Windows extensions live entirely in `src/QNotch/Modules/<Name>/`, with one entry in `ModuleList.cs`. Follow [the extension checklist](ARCHITECTURE.md#add-a-new-extension). Honor snapshot/demo mode, publish state only when it changes, and document risky shared-file needs in the pull request. Discuss new app runtime dependencies before adding them.

Mac implementations can use equivalent module concepts without inheriting WPF types or Windows APIs. Share stable identifiers, protocols, and fixtures when needed. Document unsupported data explicitly instead of showing zero or claiming parity.

Secrets belong in the platform credential store. Explain network requests in the relevant feature's settings and let users turn optional requests off.

## Labels and reviews

Use `platform:windows`, `platform:macos`, or `platform:shared` for app work, and `area:website`, `area:ci`, or `area:releases` for those areas. Combine them with `bug`, `enhancement`, or `documentation` as appropriate. Definitions are in [.github/labels.yml](.github/labels.yml); preserve unrelated labels.

A platform-specific PR needs evidence for that platform. Shared changes should identify affected implementations and fixtures. Keep performance claims and screenshots labeled by platform. Signing identities and credentials are configured privately for release workflows.

## Style

Match the surrounding code and keep UI copy short and concrete. Avoid unrelated formatting changes or premature abstractions. By contributing, you agree that your work is licensed under the [MIT License](LICENSE).
