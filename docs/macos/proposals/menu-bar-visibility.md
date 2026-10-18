# Proposal: let users hide the macOS menu-bar icon

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).

## Problem and evidence

Users who interact through the notch should be able to hide the extra menu-bar icon. In this Mac context, this proposal interprets “taskbar icon” as the menu-bar status item. The app already uses accessory activation and `LSUIElement`, so a normal persistent Dock icon is not the missing setting.

[Application.swift](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Application.swift#L50) creates an NSStatusItem unconditionally. Its menu offers Open Panel, Settings, updates, game-mode control and Quit. Hiding it must preserve access to those actions. Source inspection confirms the unconditional creation; the exact running binary revision was not supplied and native behavior has not been reproduced in this review.

## Proposed behavior

Add **Show menu-bar icon** under Settings → General, enabled by default for new and existing users. Apply changes immediately and persist them. Hiding the status item does not quit the app, hide the notch, change Dock behavior, stop modules or change login behavior.

Keep Settings available from the notch. Add a dependable recovery route: reopening QNotch from Finder or Spotlight brings Settings forward in the existing instance, even when game mode blocks the panel and hotkeys are disabled or taken by another app. The current instance-lock path exits on a second launch; simply instructing users to launch again would not work today. Specify reopen delivery for both an ordinary app reopen and a second process before implementation, while retaining one instance and no lock bypass.

Quit, update controls and manual game-mode override must remain reachable from Settings or another documented route when the status menu is hidden. Restore any diagnostics previously shown only in the menu to a reachable Settings surface. Do not force-enable a user-disabled hotkey just to supply recovery.

## Acceptance criteria for a later implementation

- Turning the setting off removes the status item immediately; turning it on restores exactly one working item with its menu and current state.
- The saved choice survives quit/restart, login launch and updates; settings with no key keep today's visible default.
- The notch remains interactive and Settings can restore the icon without a restart.
- With the icon hidden, game mode forced on, and all panel/search hotkeys disabled or unavailable, reopening the app still opens Settings in the existing instance.
- Launch/reopen handling respects the per-data-directory instance lock, never creates duplicate providers, and does not mix isolated test data with the normal app instance.
- Quit, update checks, diagnostics and game-mode override remain accessible through the documented alternate route.
- Verify VoiceOver naming, keyboard recovery, multiple on/off cycles and relaunch with an isolated data directory; capture a native before/after screenshot that excludes unrelated menu-bar content.

## Decision and validation

Recommended: a simple persistent General switch with native reopen recovery, rather than a “minimal mode” that changes several unrelated preferences. This proposal covers macOS menu-bar visibility only; Windows taskbar/tray preferences would need a separate platform review.

Fresh native build/smoke verification is pending because full Xcode 15+ is missing on the review machine. Add reopen and status-item lifecycle coverage before implementing this preference.
