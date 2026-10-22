# Proposal: let users hide the macOS menu-bar icon

Status: implemented in a macOS feature PR; validation and remaining limits are recorded below.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).

## Problem and evidence

Users who interact through the notch should be able to hide the extra menu-bar icon. In this Mac context, this proposal interprets “taskbar icon” as the menu-bar status item. The app already uses accessory activation and `LSUIElement`, so a normal persistent Dock icon is not the missing setting.

[Application.swift](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Application.swift#L50) creates an NSStatusItem unconditionally. Its menu offers Open Panel, Settings, updates, game-mode control and Quit. Hiding it must preserve access to those actions. Source inspection confirms the unconditional creation; the exact running binary revision was not supplied and native behavior has not been reproduced in this review.

## Proposed behavior

Add **Show menu-bar icon** under Settings → General, enabled by default for new and existing users. Apply changes immediately and persist them. Hiding the status item does not quit the app, hide the notch, change Dock behavior, stop modules or change login behavior.

Keep Settings available from the notch. Add a dependable recovery route: reopening QNotch from Finder or Spotlight brings Settings forward in the existing instance, even when game mode blocks the panel and hotkeys are disabled or taken by another app. The current instance-lock path exits on a second launch; simply instructing users to launch again would not work today. Specify reopen delivery for both an ordinary app reopen and a second process before implementation, while retaining one instance and no lock bypass.

Quit, update controls and manual game-mode override must remain reachable from Settings or another documented route when the status menu is hidden. Restore any diagnostics previously shown only in the menu to a reachable Settings surface. Do not force-enable a user-disabled hotkey just to supply recovery.

## Acceptance criteria

- Turning the setting off removes the status item immediately; turning it on restores exactly one working item with its menu and current state.
- The saved choice survives quit/restart, login launch and updates; settings with no key keep today's visible default.
- The notch remains interactive and Settings can restore the icon without a restart.
- With the icon hidden, game mode forced on, and all panel/search hotkeys disabled or unavailable, reopening the app still opens Settings in the existing instance.
- Launch/reopen handling respects the per-data-directory instance lock, never creates duplicate providers, and does not mix isolated test data with the normal app instance.
- Quit, update checks, diagnostics and game-mode override remain accessible through the documented alternate route.
- Verify VoiceOver naming, keyboard recovery, multiple on/off cycles and relaunch with an isolated data directory; capture a native before/after screenshot that excludes unrelated menu-bar content.

## Decision and validation

Recommended: a simple persistent General switch with native reopen recovery, rather than a “minimal mode” that changes several unrelated preferences. This proposal covers macOS menu-bar visibility only; Windows taskbar/tray preferences would need a separate platform review.

The implementation adds a local `showMenuBarIcon` preference (default true, including absent keys), one native status-item owner, and an argument-free Settings recovery endpoint scoped to the locked data directory. Finder/Spotlight reopen events open General in the running app. A second executable process must lose the existing advisory lock, deliver the same Settings request to its owner, and exit before constructing a shell or providers. No shortcut is enabled for recovery. The secure transport is reused, but the recovery handler never constructs the general debug command dispatcher or enables `debug.sock`.

Settings, About exposes Quit alongside the existing update controls and now shows the same storage/display issue banner as General. Settings, Game mode retains Automatic/On/Off for the session. Menu restoration reads current module menu actions and game-mode state. Notch/module/login/Dock behavior is unchanged; this choice stays local rather than traveling in setup codes.

Validation on 2026-10-22 used macOS 26.3, Apple silicon and Swift 6.2.3 through the documented `/Applications/Xcode.app` fallback:

- Release build with warnings as errors passed.
- The native lifecycle check passed three off/on cycles, stable ownership on refresh, functional restored Settings/module actions, current game-mode state, accessible icon naming, unchanged modules/preferences and Settings access with every shortcut disabled.
- The real-process integration passed native app reopen (`open -a` to a unique test bundle, the Launch Services reopen event), second-process delivery with forced game mode and disabled shortcuts, retained locks, isolation from a second data directory, real Settings switch actions, Quit from Settings, saved hidden state after relaunch and recovery without `debug.sock`.
- Offscreen General/About/Game mode snapshots passed their manifest/outline checker and were visually inspected. [Visible](images/menu-bar-visible.png) and [hidden](images/menu-bar-hidden.png) are native General page renders from the lifecycle test; it also captures only QNotch’s own status button, excluding unrelated menu-bar contents. The inactive native switch uses a gray track; its thumb position and outline distinguish the states.
- All 42 repository checks passed. All 136 XCTest regressions passed, including seven menu-bar visibility tests with three distinct missing-key migration cases and asynchronous recovery coverage. The regressions use XCTest to retain the documented Xcode 15 / Swift 5.9 baseline.
- The full graphical smoke **did not pass**. After the lifecycle, Terminal, timer, search, notifications and agent-process checks passed, it failed with `agents-hook: Agent hook events did not reach the board`. The smoke session itself had `needsYou` status; `agents.log` recorded `t3_running=true` and `t3_sessions=5`. The assertion also expects the entire board’s pill text to equal `demo-app needs you`, which live T3 sessions affected. No passing CI run is inferred. An earlier attempt also hit `timer-wake` while offscreen snapshots were running; the serial rerun passed that check.

The smoke harness now collapses the panel between the feature-visibility case and Terminal’s toggle-to-open case; otherwise the latter toggles an already-open panel closed. No Terminal behavior changed.

Physical VoiceOver speech, macOS 13 hardware, actual login-session launch and installation of a signed update remain manual checks; settings persistence covers their shared file-loading path.
