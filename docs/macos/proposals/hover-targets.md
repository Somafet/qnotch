# Proposal: expand the feature under the pointer on macOS

Status: implemented as an opt-in macOS interaction; see the implementation notes below.
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

## Original proposal decision and validation

Agree whether hover should navigate by default or be optional. Recommended: segment-aware opening on first expansion, with no hover-driven switching while already open. Prototype RAM/System first; record movement between the wing and body before extending to all segments. Add target-routing/state tests and native interaction evidence.

Evidence is source plus the user's expectation. Native hover routing has not been exercised in this review.

## Implementation

The General option **Open hovered feature** defaults to off, including settings saved before this feature. `hoverOpensSegment` persists in `general.json`; it is local and is not included in setup codes. Enabling it selects the final live segment under the pointer when the existing dwell expires. The shell converts the actual slot's view coordinates to screen coordinates, so a segment spilling into the other wing keeps its destination. It only resolves while collapsed: entering another status while expanded never changes the selected content. Bare housing, static indicators and peeks retain ordinary navigation.

Destination metadata belongs to each `SegmentContribution`. Timer's ring and text open Timer; Media, Notifications and Agents open their tabs. Weather reveals its Home card. Hidden tabs and missing/disabled destinations fall back to Home. CPU, memory, GPU and network reveal and scroll to System on Home, marking the selected reading with the accent background/text and an accessibility selected state. Unavailable readings remain explicitly unavailable; no RAM tab is added.

For a hidden System card, the authorized lightweight design is a temporary **System details** view inside the existing panel body with **Back to Home**. The module supplies a fresh live card body. It samples only while visible, and does not change `hiddenCards`, card order, feature enablement or tab registration. Leaving the view or closing releases it; disabling its owner also removes it. The next ordinary opening uses Home again.

Every actionable status has an accessible button name and tooltip. Clicking, accessibility press, or Return/Space on a focused status uses the same route independently of the hover option; explicit activation grants keyboard control. The standard panel hotkey/menu item plus tabs/Home cards remain keyboard equivalents. Hover uses the nonactivating opening path. Pinning, game mode, close suppression, peeks and display placement still use the existing shell paths.

Regression coverage is in `HoverTargetTests.swift` (settings migration/persistence, final-target choice, latch, live spilled coordinates, transient lifetime/layout preservation, hidden/missing destinations, peeks, game mode, accessible press and keyboard action). The offscreen snapshot and native smoke pipelines exercise real module destinations through `HoverTargetSmoke`, including selected CPU/memory snapshots and the hidden System surface. The separate `hover-dwell` smoke check moves the OS pointer from CPU to RAM before the production dwell timer expires, crosses CPU while expanded, checks explicit-close suppression, then leaves and reopens CPU. Entry/exit invoke the production tracking callbacks; this is scripted pointer evidence, not a human trial. The pointer and isolated preferences are restored. XCTest cases preserve the documented Xcode 15/Swift 5.9 baseline. Actual local check results are recorded in the implementing PR; hardware display reconnection and a physical macOS 13 machine remain manual checks.

Local validation on 2026-10-22 (Apple silicon, macOS 26.3, Swift 6.2.3): release build with warnings as errors, all 136 XCTest cases, all 38 native smoke checks, complete offscreen snapshots, both snapshot-directory checks, and all 42 repository checks passed. Changed General/System images and actual-dwell CPU/RAM images were inspected. The real dwell trace confirmed memory still routes correctly after spilling to the left wing. The smoke driver waits for the production opening with a bounded timeout because AppKit can issue a later entry event and restart dwell; it asserts that RAM is crossed while still collapsed and never waits for a particular metric. The original probe's premature deadline assertion and the existing Terminal smoke setup failure were preserved locally; the latter was fixed by closing the primary panel between visibility and Terminal cases, without changing Terminal behavior or assertions.
