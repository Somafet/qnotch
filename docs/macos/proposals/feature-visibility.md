# Proposal: make Search and feature visibility configurable on macOS

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Problem and evidence

Users should be able to remove Search, the focus timer and other unused surfaces. The app already supports turning most features off, but Search behaves differently and “hide” currently mixes distinct intentions.

[Settings → Features](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/SettingsController.swift#L445) enumerates modules and toggles them immediately. [ModuleList](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Modules/ModuleList.swift#L20) already includes Timer, so disabling the entire timer is supported. Appearance and Home edit mode also hide individual Home cards. However, [ShellController.tabs](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/ShellController.swift#L424) always prepends Home and Search; Search is a shell feature, outside the module switch list.

## Proposed behavior

Offer two clearly named choices where relevant:

- **Show in panel**: choose whether a tab or Home card is visible while keeping useful background behavior, such as an active timer or agent alerts.
- **Enable feature**: keep the existing module lifecycle control that removes the feature's listeners, timers, shortcuts and contributions.

Add a persisted Search enable switch beside feature controls, with Search enabled for existing users. When disabled, remove its tab and deactivate its hotkey, Command-F and type-to-search entry paths. Do not accidentally register an invisible global shortcut. Keep the saved shortcut for restoration. Searchable content from a hidden-but-enabled module can remain searchable; a disabled module must contribute no results.

Hide a Timer tab/card without cancelling a running timer. Disabling the entire timer follows an explicit, documented decision for an active countdown; avoid conflating this with a cosmetic hide action. Home and Settings remain reachable so a user can restore features.

## Acceptance criteria for a later implementation

- Search can be disabled and re-enabled immediately, with persistence across restart and migration from settings without the new key.
- Search cannot be reached through its tab, shortcut, Command-F or ordinary typing while disabled. Toggle-panel and Settings remain available.
- Timer can be hidden from Home and the tab strip while an active countdown continues and its configured completion behavior still works.
- Whole-module disabling still stops its providers and removes its contributions; re-enabling restores saved order and visibility.
- Hiding/disabling the active tab selects a valid Home fallback. Hiding all optional tabs leaves a usable panel without empty slots.
- Specify setup-code import/export compatibility before changing shared preferences; unknown Mac-only keys must not break Windows imports.
- Native checks cover enable/disable while open, active countdown, keyboard entry paths, restart and restore.

## Decision and validation

Agree on the labels and which controls are independent before implementing. Recommended: preserve existing module switches, add Search enablement, and expose per-tab visibility alongside the existing per-card layout controls. Do not add a second redundant “disable Timer” switch.

Source confirms the availability gap for Search. Other discoverability and active-timer expectations are design proposals requiring native validation; no settings were changed during this review.
