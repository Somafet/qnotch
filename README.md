# QNotch

A small notch at the top of your desktop for music, system stats, files, clipboard history, and coding agents. Hover it to open the panel.

Free and open source under the [MIT license](LICENSE). No account required.

## Platforms

- **Windows: available.** The existing C#/.NET 10 WPF app stays in `src/QNotch/`. [Download Windows](https://github.com/Somafet/qnotch/releases/latest) · [Windows guide](docs/windows/README.md) · [Build and test](docs/windows/development.md).
- **macOS: planned.** No download, build target, minimum OS version, or framework has been selected. [Mac port status and contribution scope](docs/macos/README.md).

Both ports belong in this repository and can release independently. A feature being available on Windows does not imply Mac support. The landing page and interactive demo currently describe Windows.

![The QNotch Windows panel](docs/images/home.png)

![The collapsed Windows pill](docs/images/pill.png)

## What it does

The released Windows app includes:

- System stats, now-playing controls, weather, and mic/camera activity indicators.
- Clipboard history, a file tray with browser-based phone transfers, notes, and search.
- Live Claude Code and Codex sessions, AI usage limits, GitHub contributions, and script notifications.
- Volume, a timer, a screen color picker, and Windows scheduled tasks.
- Reorderable cards and tabs, per-app positioning, multi-monitor support, and a passive Game mode.

Disabled features are never loaded. See the [Windows guide](docs/windows/README.md) for behavior and limitations and the [notification reference](docs/notifications.md) for integrations.

![Windows Agents tab](docs/images/agents.png)

## Install

Windows 10 2004 or newer, x64. Choose `QNotch-self-contained.zip` to run without installing .NET, or `QNotch.exe` if you have the .NET 10 Desktop Runtime. [Download and first-run instructions](docs/windows/README.md#install). There is no Mac download yet.

## Updates

Windows supports automatic checks and explicit update installation. [Update settings and recovery](docs/windows/README.md#updates). GitHub's global latest release remains the Windows channel for existing installations. Future Mac releases must use a separate channel; see [release compatibility](docs/releases.md).

## Hotkeys

Windows defaults include Ctrl+Alt+N to toggle the panel, Ctrl+Alt+F to search, and Ctrl+Alt+G for Game mode. [All shortcuts](docs/windows/README.md#hotkeys).

## Sounds

[Windows sound settings](docs/windows/README.md#sounds) support system sounds and custom audio files.

## Privacy and data

The Windows app stores settings, notes, and logs locally, and secrets in Windows Credential Manager. Clipboard history stays in memory unless you choose to save it. Optional integrations and update checks make network requests. [Data locations and network behavior](docs/windows/README.md#privacy-and-data). Mac data locations and permissions will be documented with its implementation.

## Performance

The existing Windows measurements are about 0.08% of one core and 42 MB resident memory while collapsed and idle, and about 500 ms to the visible pill. These are Windows observations, not Mac targets or benchmarks. [Measurements, targets, and known limitations](docs/windows/README.md#performance).

## Build

Choose the area you are working on:

- [Windows development](docs/windows/development.md): .NET 10 build, updater/phone-sharing tests, snapshots, and both publish profiles.
- [macOS development status](docs/macos/README.md): no executable target yet.
- [Website](website/README.md): independent Astro project.
- [Repository tooling and CI](docs/releases.md#required-checks): Node.js 24+, `npm ci`, then `npm test` from the root.

The existing `QNotch.sln` remains a Windows solution. A Mac contributor does not need to build it.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md). [ARCHITECTURE.md](ARCHITECTURE.md) separates shared principles from Windows implementation rules; [spec/README.md](spec/README.md) holds common behavior and compatibility fixtures. [SPEC.md](SPEC.md) preserves the original Windows design. [Documentation index](docs/README.md).

## License

[MIT](LICENSE)
