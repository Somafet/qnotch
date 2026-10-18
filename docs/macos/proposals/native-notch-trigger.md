# Proposal: open from the physical notch area on macOS

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Problem and evidence

Moving the pointer into the physical camera housing should be enough to open QNotch. This is a reported interaction gap, not yet a reproduced native event-delivery defect. The existing display geometry already reserves the hardware camera housing; the request is to make that region a dependable trigger, rather than requiring users to find a visible wing.

[DisplayLayout](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMacCore/DisplayLayout.swift#L28) already calculates the housing from safe-area and auxiliary geometry. [Surface tracking](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/NotchPanel.swift#L164) uses a window tracking area, and [pointerEntered](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/ShellController.swift#L348) checks the settled frame before opening. The mathematical frame includes the housing, but that alone does not establish whether AppKit delivers events beneath the physical notch.

## Proposed behavior

Use the native housing rectangle as a logical activation target, alongside visible status wings. Verify OS event delivery first; reuse the current tracking approach where possible. If a fallback is needed, choose the narrowest scoped mechanism that works without an Accessibility/Input Monitoring permission request or continuous idle polling. Do not add a broad screen-top activation strip.

Keep the existing hover dwell, leave delay, explicit-close suppression, and keyboard-focus rules. Use display-local geometry converted to global points. A display with no reported housing keeps its existing floating-pill target.

## Acceptance criteria for a later implementation

- On a physical notched Mac, approach the hardware housing from left, right, and below, including when no wing content is visible; each approach opens once after the configured dwell.
- Keep controls below the housing and leave the menu bar outside the activation region usable.
- Hover opens without taking the keyboard; click/hotkey still explicitly grants it.
- After Escape under the target, remaining there does not immediately reopen; leaving and re-entering works.
- Game mode prevents hover opening. Display disconnect, reconnect, scaling, sleep/wake and negative-origin secondary displays recompute the target.
- Test a non-notched external display and invalid housing-geometry fallback.

## Decision and validation

Confirm whether activation anywhere beneath the hardware housing is the preferred default. Compare native tracking delivery with actual pointer-coordinate observations before selecting an implementation. Add geometry/state regressions and physical-hardware recordings; a synthetic geometry test cannot settle native event delivery.

No native reproduction was run: the review machine lacks full Xcode. No screenshot can prove this hover behavior; the user report is the current interaction evidence.
