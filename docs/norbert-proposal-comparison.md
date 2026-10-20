# Norbert's proposals: priorities and Windows comparison

Reviewed on 2026-10-20 against main commit `7f1088e726731e695a83981d801e119f875e03bf`.

All seven PRs are documentation-only proposals for the native macOS app. Several are worth pursuing, but merging them alone would not change app behavior. The strongest defect candidate is Mac Search containment. Windows overlap is mainly navigation and customization.

## Comparison

| Proposal | Recommendation | Windows assessment |
| --- | --- | --- |
| [#62 Search containment](https://github.com/Somafet/qnotch/pull/62) | **First.** Fix the bounded results viewport and keyboard selection. Six Mac rows need 320 points in a roughly 308-point host. Record native frames before declaring the precise clipping cause resolved. | **Did not reproduce.** Windows scrolls within a fixed panel and supports Up/Down/Enter. An isolated runtime check with 11 results confirmed scrolling and selected-result activation without moving or resizing the panel. |
| [#61 Status gutters](https://github.com/Somafet/qnotch/pull/61) | **Pursue on Mac.** A focused polish fix: anchor clusters to consistent outer gutters while retaining camera clearance and the symmetric silhouette. | **Different layout.** Windows uses a content-sized horizontal strip without symmetric wings around a camera housing. The reported centering formula does not apply. |
| [#63 Feature visibility](https://github.com/Somafet/qnotch/pull/63) | **Pursue, split the scope.** Add Mac Search enablement first. Treat independent tab visibility as a separate enhancement. Preserve useful background behavior when hiding a surface. | **Partial overlap.** Search and Timer can already be disabled, with changes applied on restart. Home cards can already be hidden. Independent tab hiding while a feature remains enabled is missing on both platforms. |
| [#64 Panel headers](https://github.com/Somafet/qnotch/pull/64) | **Pursue selectively.** Standardize title/action alignment on list and utility tabs. Keep intentional exceptions for Media, Home and Search rather than forcing every body into the same layout. | **Shared design inconsistency.** Clipboard starts with filters, AI with "Usage," and Media with track content. Windows source and snapshots confirm there is no uniform page heading. |
| [#60 Segment-aware hover](https://github.com/Somafet/qnotch/pull/60) | **Prototype.** Useful, but changes navigation expectations. Latch one destination per opening; consider a preference and provide a click equivalent. | **Same enhancement opportunity.** Hover opens the generic panel here too. Both platforms need contribution-owned destination metadata. RAM should reveal System details rather than route to a nonexistent RAM tab. |
| [#59 Physical-notch trigger](https://github.com/Somafet/qnotch/pull/59) | **Investigate first.** Test native event delivery on an actual notched Mac before choosing an implementation. Geometry alone cannot prove this defect. | **Mac-specific report.** Windows activates from the painted pill and has no equivalent hardware-housing trigger contract. |
| [#65 Hide menu-bar icon](https://github.com/Somafet/qnotch/pull/65) | **Optional, lower priority.** Add the preference after reliable reopen-to-Settings recovery, including game mode and unavailable hotkeys. Keep Quit, updates and game-mode controls reachable. | **Tray equivalent is also missing.** The main taskbar button is already hidden. The tray icon is unconditional, and a second launch exits without reopening Settings. A tray-visibility preference would therefore need its own recovery path. |

## Suggested implementation order

1. Fix Mac Search containment and selected-result keyboard navigation, with a populated-search native smoke case.
2. Correct Mac status gutters and add Mac Search enablement as focused changes.
3. Design independent tab visibility and consistent utility-tab headers for both platforms, keeping implementation native to each OS.
4. Prototype segment-aware opening before deciding its default behavior.
5. Reproduce hardware-notch activation on a physical Mac. Keep menu-bar/tray visibility lower priority until recovery behavior is implemented.

Use focused implementation follow-up PRs. The proposals themselves are review material, not implemented fixes or release approval.

## Windows verification

The reviewed Windows source at local commit `5ee60df` was identical to the Windows source on the main commit above.

- Release build passed with zero warnings and zero errors: `dotnet build src/QNotch/QNotch.csproj -c Release -warnaserror`.
- Dark snapshots for the pill and all panel tabs passed, `snapshot.txt` ended in `done`, and `node scripts/check-snapshots.mjs <output>` passed. Media, Clipboard, AI, Files and pill PNGs were visually inspected for the layout comparison.
- A debug instance used its own data directory and unique instance name, with updates disabled and only System stats, Note and Search enabled. Five synthetic note lines plus tab/settings matches produced 11 search hits.
- Empty and populated Search both reported the same panel frame: `x=920`, `y=0`, `width=720`, `height=380` in DIPs on the test display.
- Ten Down presses moved selection from the first result to the final result, Appearance, and scrolled it into view. Return opened the Appearance settings page. The search field retained focus while selecting results.
- After disabling Search and restarting the isolated instance, its module reported `enabled=false` and `running=false`. The search shortcut returned `no search hotkey (is its feature turned on?)`; selecting Search returned `no tab with id search (tabs: home)`.
- Test instances were stopped after verification. No app source, release assets or user settings were changed by the review.

These checks cover the reported Windows search overlap and the observed layouts. They do not establish correctness for every display configuration, localization or content state.

## Source evidence

Links are pinned to the reviewed main commit so later implementation changes do not alter the evidence.

- Windows [search layout and keyboard handling](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Modules/Search/SearchModule.cs), [shell hover and pill construction](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Shell/ShellController.cs), and [segment contract](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Modules/Contracts.cs).
- Windows [module/card/tab preferences](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Core/GeneralSettings.cs), [feature switches](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Shell/Settings/FeaturesSection.cs), and [Home card visibility](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Shell/Settings/AppearanceSection.cs).
- Windows [window and taskbar configuration](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Shell/NotchWindow.xaml), [tray lifecycle](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/Shell/TrayIcon.cs), and [second-launch handling](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch/App.xaml.cs).
- Mac [Search layout](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch.Mac/Sources/QNotchMac/Shell/PanelView.swift), [display geometry](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch.Mac/Sources/QNotchMacCore/DisplayLayout.swift), and [embedding constraints](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch.Mac/Sources/QNotchMac/Shell/Controls.swift).
- Mac [hover, tabs and wing placement](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch.Mac/Sources/QNotchMac/Shell/ShellController.swift) and [status-item/instance lifecycle](https://github.com/Somafet/qnotch/blob/7f1088e726731e695a83981d801e119f875e03bf/src/QNotch.Mac/Sources/QNotchMac/Application.swift).

## Mac verification limits

Mac was source-reviewed on Windows. No native Mac build, hardware-hover test or fresh reproduction of the reported clipping was run. The proposals' screenshots were described in their documents; their private originals were not inspected during this review. The exact AppKit constraint failure behind upward clipping remains unproven.

Current main was checked rather than assuming the proposals' older baseline still applied. It still has the non-scrolling six-result Search layout, first-result Return handling, unconditional Search tab, centered wing content and unconditional normal-run status item described above.
