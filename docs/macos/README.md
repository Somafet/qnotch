# QNotch for macOS

Status: planned. There is no Mac executable, supported macOS version, installation command, or build target yet. Windows releases and screenshots do not establish Mac feature support.

## Source and contribution scope

`src/QNotch.Mac/` is the reserved source location. The UI framework is undecided: a native Swift implementation and a Rust/GPUI implementation remain options. Do not add a placeholder project or require the .NET Windows SDK merely to work on this port.

Start with [shared principles](../../spec/README.md), [architecture](../../ARCHITECTURE.md), and [contributing](../../CONTRIBUTING.md). Keep OS providers, credential storage, window behavior, permissions, and packaging inside the Mac implementation. Share protocol specifications and fixtures where there is an actual compatibility requirement.

The first implementation should document:

- Toolchain, build/test/launch commands, minimum macOS version, and supported architectures.
- Module availability and differences from Windows, especially media sessions, clipboard monitoring, scheduled jobs, fullscreen behavior, and mic/camera attribution.
- Data and log locations, permission prompts, and how to run tests without touching a user's settings.
- Snapshot or equivalent UI checks, accessibility checks, and measured launch time, idle CPU, wakeups, and memory footprint. Windows working-set numbers are not Mac benchmarks.

## CI and first release

Add a real macOS runner job with the first build target and include it in the required `build` aggregate. Keep pull-request builds unsigned and independent of signing credentials. Do not create a permanently skipped or empty job to imply a working port.

Reserve `macos-vX.Y.Z` tags and `QNotch-macos-{arm64,x64,universal}.{dmg,zip}` artifact names. These are conventions, not promises to ship every architecture or format. Mac releases must use the [guarded publisher and release policy](../releases.md), never become GitHub's global latest release, and have an explicit platform update feed. Sparkle is an option, not yet a dependency.

Before a public download, configure Developer ID signing, hardened runtime, notarization, and stapling where applicable; validate the downloaded app on a clean Mac. Store signing identities and credentials privately in release secrets. Do not put personal account details in the repository or issues. Signing setup belongs with the real release workflow, not this preparation.
