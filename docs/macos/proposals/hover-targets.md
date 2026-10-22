# Proposal: expand the feature under the pointer on macOS

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Problem and evidence

Hovering a RAM reading suggests a way to inspect memory, but currently opens the generic panel. Treat the visible statistic as a destination rather than decoration. This is a proposed interaction change, not a broken existing module action.

[pointerEntered](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/ShellController.swift#L348) opens without choosing a destination. [SegmentContribution](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Modules/Contracts.swift#L19) has identity, order, slot and view factory, but no destination contract. [StatsModule](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Modules/Stats/StatsModule.swift#L30) contributes a System Home card, not a dedicated RAM tab. Do not route RAM to a nonexistent tab.

## Proposed behavior

After the existing hover dwell, open relevant content for the segment under the pointer. CPU, RAM, GPU and network should reveal the System card on Home and emphasize the corresponding metric. If that card is hidden, show a lightweight System detail surface without silently changing the saved Home layout. Discuss that detail surface before building it.

Timer routes to Timer; segments for modules with a meaningful tab route to their tab. Static indicators without a destination and the physical housing keep the ordinary open behavior. Destination metadata belongs to a contribution, not coordinate checks for hard-coded module names.

Latch the destination for that opening. Passing across other segments on the way into the panel must not switch it repeatedly. Hover never activates the app. Provide click and keyboard equivalents with an accessible name such as “Open memory details”; expose a tooltip so the interaction is discoverable.

## Acceptance criteria for a later implementation

- Hover RAM and CPU separately: the respective reading is visible after opening, with the correct destination even after segments spill to the other wing.
- Opening from bare housing retains normal navigation behavior.
- Movement from a segment into its expanded content does not switch destination or close the panel; rapid movement between segments before the dwell chooses only the final target.
- Disabled, missing, and temporarily hidden destinations have a safe Home fallback; no removed view is retained.
- Clicking and keyboard activation reach the same content. Hover retains the foreground app's keyboard focus.
- Peeks, close suppression, game mode, pinning and display changes keep their existing behavior.

## Decision and validation

Agree whether hover should navigate by default or be optional. Recommended: segment-aware opening on first expansion, with no hover-driven switching while already open. Prototype RAM/System first; record movement between the wing and body before extending to all segments. Add target-routing/state tests and native interaction evidence.

Evidence is source plus the user's expectation. Native hover routing has not been exercised in this review.
