# Proposal: contain macOS search results without displacing the panel

Status: proposal for discussion; no app behavior changes are implemented.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Problem and evidence

The supplied search screenshot shows the expanded notch cut off above the display. Search content must remain inside the panel rather than changing its top attachment.

[DisplayLayout.panelSize](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMacCore/DisplayLayout.swift#L9) sets a 376-point body. [PanelView](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/PanelView.swift#L66) leaves about 308 points for content: 376 minus top 10, tab strip 34, body gap 12 and bottom 12. [SearchView](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/PanelView.swift#L136) requires 320 points with six hits: field 36 + gap 10 + rows (6 × 44) + row gaps (5 × 2). Its top-pinned stack has a required bottom bound via [embed](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/Controls.swift#L46) and no results scroller.

That is a source-derived 12-point conflict at the intended size. It supports an overflow diagnosis, but does not prove which AppKit constraint breaks or explain the exact amount of upward displacement. Record the actual window and view frames before calling the root cause settled. The existing smoke screenshot selects empty Search and therefore does not exercise six populated rows.

## Proposed behavior

Fix the search field at the top of the content host and place results in a vertically scrolling viewport below it. Constrain that viewport to the remaining body height; keep window geometry controlled by DisplayLayout. All hits remain reachable without enlarging or moving the panel above the bezel. Bound row text horizontally and truncate long title/detail lines appropriately.

Keep the search-field first responder stable while results update. The audit also found Return always runs `hits.first`; Up/Down result selection should be considered in the same search interaction pass, with an accessible selected state and automatic scrolling to the selected result.

## Acceptance criteria for a later implementation

- With 0, 1, 5 and 6 hits, the settled window frame equals DisplayLayout's expanded frame and the header/field remain visible below the hardware housing.
- Repeat for long titles and details, rapid typing/deleting, empty/error source states, non-notched displays, smaller displays and display scaling.
- Every displayed hit is reachable by scrolling and keyboard; Return activates the selected hit once. Clearing the query resets selection safely.
- No unsatisfiable-layout warnings occur. Reduced Motion and animated tab switching both keep the body bounded.
- Add a native populated-search smoke case, record window/body/result frames, inspect its screenshot, and test query changes after opening.

## Review classification and validation

High usability finding; `rule/none` for native content-fit geometry, and `rule/search-keyboard-navigable` for the source-only keyboard finding. Screenshot evidence establishes the reported clipping; source establishes the competing height requirements. Fresh native reproduction is pending because full Xcode is absent. No fix is implemented here.
