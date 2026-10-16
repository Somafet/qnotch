# QNotch for macOS

Status: functional development milestone, not a public release. A native Swift/AppKit menu-bar app provides a display-anchored pill, hover panel, and countdown timer. It uses native controls, SF Symbols, system typography, and the macOS popover material rather than reproducing the Windows interface. Windows remains independently released.

## Requirements and commands

- Apple silicon (arm64), macOS 13 or newer. Intel and universal downloads are not supported by this milestone.
- Xcode 15 or newer, including its macOS SDK and XCTest; Swift 5.9 or newer. No package dependencies or Windows tooling.
- A logged-in graphical macOS session for the native UI smoke test and interactive app. Headless geometry/state/settings tests run through XCTest.
- The deployment target is macOS 13. CI runs on macOS 14; development evidence also records the local OS. Compatibility on a physical macOS 13 machine still needs validation before a public release.

From the repository root:

```sh
bash scripts/macos/build.sh
bash scripts/macos/test.sh
bash scripts/macos/smoke.sh
open dist/macos/QNotch.app
```

Builds produce `dist/macos/QNotch.app` with release optimization and warnings treated as errors. No signing account, certificate, provisioning profile, or network service is needed. The development app bundle has no Developer ID signature or notarization. The toolchain may emit a local ad hoc executable signature; that is not distribution signing. Do not distribute this build as a public download.

If Command Line Tools are selected, the build/test scripts use `/Applications/Xcode.app` when available, for that process only. For a different Xcode installation, set `DEVELOPER_DIR` to its `Contents/Developer` directory. They report a missing full Xcode installation explicitly. They never change the machine-wide developer directory. Use `xcrun swift --version` to inspect an explicitly selected toolchain.

For an isolated interactive session:

```sh
QNOTCH_MAC_DATA_DIR="$(mktemp -d)" open -n dist/macos/QNotch.app
```

Alternatively, launch the executable with `--data-dir /absolute/temporary/directory`. Each data directory has its own advisory instance lock. Quit only the test instance you started, using its menu or PID. A second instance with the same directory exits instead of silently overwriting settings.

## Behavior and availability

- Choose the main display or a specific connected display in Settings. If the selected display disconnects, QNotch falls back to the main display and reports the unavailable selection; reconnecting restores it. With no display, the panel is hidden.
- Placement uses `NSScreen.safeAreaInsets` and its auxiliary top areas. The surface starts immediately below the camera housing's safe boundary, keeping every control visible. Displays without a notch use a pill six points below the menu-bar working area. Coordinates are points, including negative display origins; no model-name or fixed notch-width heuristics.
- Hover opens after 120 ms and collapses 400 ms after leaving. Hover never activates the app or accepts keyboard input. Clicking the pill/panel or choosing **Open Panel** explicitly grants keyboard focus. A keyboard-opened panel stays open on pointer leave; Escape, outside click, or key-window loss closes it. Closing never forces focus back after the user has already switched apps.
- Home hosts the countdown card; Timer is a registered tab. Search finds the timer through a registered in-memory search source. Native buttons, search field, segmented controls, display picker, and checkboxes have accessibility labels. The menu-bar item provides keyboard access without a global event-tap permission or global shortcut.
- Presets are 5, 15, 25, and 50 minutes. Start, pause/resume, and reset work locally. A running timer continues across sleep and refreshes on wake. It stops on quit; only preferences persist. Completion updates the pill and optionally plays the system beep without taking focus or prompting for notification permission.
- Turning Countdown off takes effect immediately, stops its scheduler, and removes all five contributions. The panel explains how to enable it instead of showing a fake timer.
- Reduced motion follows both the user's local setting and the OS setting. Only a finite opening fade is used. No display link, frame loop, repeating idle timer, or hidden countdown animation runs.
- Media sessions, clipboard history, scheduled jobs, fullscreen/game detection, mic/camera attribution, file sharing, autostart, and automatic updates are unavailable. Fullscreen auxiliary panel presentation is requested from macOS, but game-mode behavior is not ported. No parity with Windows is claimed.

## Module and platform boundaries

`Sources/QNotchMac/Shell/` owns AppKit windows, focus, hover, display events, navigation, search hosting, and general settings. `Modules/Contracts.swift` defines five local registries: **cards, tabs, status segments, search sources, and settings sections**. `ModuleList.swift` is the only composition file naming concrete modules. A disabled module is never constructed. Each module owns its state, providers, views, and preferences; it receives visibility and active-tab changes rather than inspecting window internals.

`Modules/Timer/` supplies the real countdown module. A visible running countdown refreshes at most once per second; collapsed or hidden content schedules only its completion deadline. A stopped or paused timer has no scheduled work. Its collapsed segment says Running rather than refreshing seconds nobody is inspecting. Completion is a justified one-shot background wake. Sleep/wake and clock-change events reconcile the wall-clock deadline; changing the system clock can change the remaining duration.

`QNotchMacCore` contains Mac-local, testable geometry, countdown, shell-state, settings, and update-channel rules. It is not a cross-platform runtime and is not referenced by Windows. macOS APIs and future credential-store integrations stay inside this implementation.

## Data, permissions, and diagnostics

Default local root: `~/Library/Application Support/QNotch.Mac/`. `general.json` stores the selected display, reduced motion, and module enablement; `timer.json` stores duration and completion sound. Writes are atomic. Missing files use defaults. Corrupt files remain intact until the user explicitly saves replacement preferences; Settings reports unavailable storage and session-only changes. Display IDs are supplied by macOS and may change after hardware/system reconfiguration; fallback is explicit.

`logs/session.log` contains bounded startup timing only and is replaced each launch. It contains no account identity, display names, credentials, or user data. `QNOTCH_MAC_DATA_DIR` and `--data-dir` replace the entire root, including logs and the instance lock. Secrets must go in Keychain when a module eventually needs them. This milestone has no network requests, analytics, Accessibility permission, Screen Recording permission, or notification authorization prompt.

`smoke.sh` uses a unique temporary data root, exercises the actual AppKit shell and timer scheduler, exports pill/Home/Timer/unavailable PNGs, and requires a final `done` in `dist/macos/smoke/smoke.txt`. It fails without a graphical display or on a timeout. Inspect the PNGs after UI changes; snapshots do not capture another application's screen. CI uploads them as `macos-smoke`. Geometry tests cover camera-safe placement, non-notched external displays with negative origins, and clamping; physically reconnecting multiple displays still needs a manual hardware check.

## Performance: targets and evidence

Mac development targets: collapsed stopped-timer CPU at or below 0.1% of one core, zero app draw callbacks after settling, no app-scheduled repeating idle work, process-start-to-panel-ordering below 500 ms, and resident memory below 80 MiB. These are targets, not guarantees or imported Windows benchmarks. A hidden running timer retains one completion wake; an expanded running timer can wake once per second.

Run the release build, keep the pointer away from the pill, and measure an isolated process:

```sh
bash scripts/macos/measure.sh
```

This waits three seconds, then records one 30-second collapsed-idle interval using `proc_pid_rusage` CPU time, resident size, and interrupt wakeups, plus app view draw counters. The two interval endpoints add no sampling loop. `dist/macos/measure/performance.json` records the source revision/dirty flag, app version, hardware model, physical memory, OS, state, method, elapsed interval, process-start-to-panel-ordering, and measurements. The launch metric uses the kernel process start timestamp and `mach_absolute_time`, and ends just after the panel is ordered front. It includes process startup and app initialization, but excludes waiting in Launch Services and first compositor presentation; it is not a click-to-visible benchmark. Draw callbacks do not establish compositor/GPU repaint counts, and interrupt wakeups are not total thread wakeups. Use Instruments/Energy Log for those measurements before making stronger claims. Include commit/build, hardware, memory, OS, state, interval, and method in any recorded evidence; keep results separate from targets.

## CI and future releases

The `macos` CI job uses an Apple silicon `macos-14` runner to build the real target, run XCTest regressions, and run native UI smoke validation. It is part of the required `build` aggregate alongside Windows, repository, and website validation; any failure, cancellation, or skipped dependency rejects the gate. PR builds do not use signing secrets. No release is published by these scripts or CI changes.

The Mac update channel is reserved separately in `QNotchMacCore/UpdateChannel.swift`: filter the releases collection for valid `macos-vX.Y.Z` tags, never GitHub's global `/releases/latest`. Automatic updates and an appcast are unavailable in this milestone; adopting Sparkle remains a later decision.

Mac release tags use `macos-vX.Y.Z`; artifacts use the supported `QNotch-macos-arm64.{dmg,zip}` convention. Use the existing [guarded publisher](../releases.md) with `--platform macos`, which always keeps `--latest=false`. Do not create a Mac release through an unguarded command. Windows tags, updater endpoint, filenames, ZIP layout, and publish profiles remain unchanged.

Before a public download, configure Developer ID signing, hardened runtime, notarization, and stapling where applicable, then verify installation on a clean Mac. Store all actual identities and credentials privately. No release or signing setup is part of this milestone.
