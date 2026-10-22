# Windows Home widget sizes

Captured on 2026-10-22 with the Windows 0.4.0 development build on Windows build 26200. These are isolated diagnostic runs with demo data; the app version is the repository's local build baseline.

All 14 Home cards support Small (218 × 148 DIPs). Weather, Now playing and GitHub also support Medium (446 × 148 DIPs), retaining their previous default widths. In Edit layout, visible left and right edge anchors snap between supported widths. The current cards have no taller variant, so they expose horizontal anchors only. Keyboard arrows/Home/End and UI Automation use the same supported sizes. Reduce motion keeps editing available without jiggle.

- [Small cards, dark](small-dark.png), with [control outline](small-dark.txt): Weather, Now playing and GitHub ordered first, all Small, Reduce motion enabled.
- [Small cards, light](small-light.png), with [control outline](small-light.txt): the same saved layout in the light theme.
- [Existing default widths, dark](default-dark.png), with [control outline](default-dark.txt): the detailed two-column layouts and resize anchors, with motion enabled.

The [snapshot report](snapshot.txt) and [dark](smoke-dark.txt) / [light](smoke-light.txt) smoke reports end in `done`; each complete output directory passed `scripts/check-snapshots.mjs`. The `card-sizes` check exercises both anchors in both directions, repeated movement below the snap threshold, cancellation, keyboard sizing, UI Automation, exact dimensions, body reuse, JSON reload, unsupported-handle absence, and a non-overlapping all-Small grid. Foreground hotkey checks report skips when Windows retains another app's focus; module-toggle is the existing restart-only skip.

The Windows regression suite additionally checks unsupported-size fallback, saved hidden/disabled card choices, setup-code inclusion, and actual WPF text/button bounds for the three adaptive cards in ready, empty, loading and error states in both themes. Updater, phone-sharing and onboarding suites also passed. No background behavior changed, and these screenshots make no idle CPU or memory claim.

A separate writable `--debug-control` test used a fresh data directory with updates disabled and only Weather enabled without a configured place. Tab reached an edge anchor, Left selected Small, quitting wrote `CardSizes.weather = "Small"` to disk, and a new app process restored it. Both processes had Reduce motion enabled and were stopped after verification; the user's instance and settings were untouched.

This completes the Windows portion of issue #90; macOS remains separate work.
