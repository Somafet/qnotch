Original proposal review: the cross-vendor second opinion was unavailable because its session quota gate declined the run.

# Design review proposal: standardize macOS panel headers and layout

Status: header contract implemented; original review retained below with its historical evidence limits. Native validation evidence is recorded under Implementation follow-through.
Platform: native macOS app. Source baseline: `ffe496d6585652d2ef6f38c15056705c9ba83867` (2026-10-18).
The reported app's exact binary revision and OS version were not supplied; source findings apply to this baseline.

## Implementation follow-through

The title/header portion of [proposal PR #64](https://github.com/Somafet/qnotch/pull/64) is implemented in the native macOS shell. `TabPageView` supplies a fixed 28pt title/action row, 14pt semibold system title, host-aligned leading edge and 12pt gap before the body. Titles come from tab registrations, including **Scheduled tasks** and **Terminal**. They remain outside scrolling, loading, unavailable and empty-state content. Long titles truncate before native actions and keep their full accessibility label. The native page group is named and linked to the static title.

Page-wide Clipboard, Files, Notifications, AI and Scheduled tasks actions occupy the fixed trailing slot. Filters, counts, usage/provider sections, Focus timer, Launch agents and Terminal's command help remain contextual body content. Redundant Files/Notifications/Terminal page headings are removed. Home retains card headings. Search retains its labeled field as an explicit exception. No new typography minimum for stat captions or generic body redesign is included.

Gutter alignment, Search containment/navigation and feature visibility already landed separately; this implementation does not redo them. The original mechanical inventory below describes the source baseline, not today's UI. The original evidence limits likewise describe the review, not the validation of this implementation.

Regression evidence: native `TabPageViewTests` exercises long/localized titles, empty and populated bodies, scrolling, hidden actions, accessible group/title linkage, action activation and focus forwarding. Both offscreen snapshots and graphical smoke now check every registered tab's title origin/baseline, 28pt row, 12pt body gap, action bounds and accessible control names; `tab-header-frames.log` records actual native frames.

Native validation on 2026-10-22 (Apple silicon, macOS 26.3, full Xcode selected by the documented script fallback): release build with warnings as errors and all 131 native tests pass. Offscreen snapshots capture every tab at 2x in the same settled panel size, plus empty Media and Files' drop state; the actual PNGs were inspected and the snapshot checker passes. All nine module title rows measure 28pt high with the same host-leading origin, 19.5pt baseline from the row top and 12pt body gap. Visible page actions end at the host's trailing edge. Home card headings and Search's field exception were inspected too. All 42 repository tests pass.

The coordinated graphical smoke run also passes all 37 checks and ends in `done`, including `tab-headers`, `terminal-input-lifecycle`, `agent-processes` and `accessible-names`; its snapshot checker passes and every module tab's actual PNG was inspected. The run used the committed implementation `8273efb03c9f9848b4337b164795f13ae78a198c`. Agents' PNG included live T3 rows alongside the seeded rows, so the capture is not evidence of fully synthetic diagnostic data isolation. This did not fail a smoke assertion in this run, and no Terminal/Agents behavior or harness change is included here. Remote CI is separate evidence.

Manual VoiceOver navigation, every provider error/loading/filter combination, physical multi-display reconnects and macOS 13 hardware validation remain outside this recorded evidence. Long/localized title geometry and hidden-action/scrolling states have automated AppKit coverage; they are not a claim that every localized module body was visually reviewed.

## Verdict

QNotch's hardware-shaped surface, dark palette and compact status display give it a clear identity. The main problems are consistency and containment: content quantity changes visual alignment, search can exceed its host, and tabs do not provide a stable heading landmark. Preserve the notch idea; make its geometry and navigation predictable.

This is a cold review of the native Mac UI, using two supplied screenshots and source at the baseline above. The mechanical audit was performed by an independent agent without the creative direction. There is no whole-app visual approval: screenshots do not show every tab, and a fresh native smoke build stopped because full Xcode 15+ is missing. Platform-specific findings below are not claims about Windows.

## Creative review

- **Hierarchy:** the compact notch should show status at a glance; expansion should answer the status the user pointed at. A generic destination makes a RAM reading a weak affordance. Consider destination-aware opening, latched once per expansion.
- **Rhythm:** the two sides share a silhouette but not a stable visual gutter. Anchor status clusters consistently rather than letting the opposite wing set their apparent padding.
- **Wayfinding:** switching tabs should retain a stable title/action row. Content such as album titles and timer modes can have their own hierarchy below it.
- **Subtraction:** let users hide unused tabs independently of disabling their background features. Preserve a clear path back to configuration.
- **Motion:** search content should scroll within a bezel-anchored surface. Neither a growing query nor a changing result list should move the header into the housing.

These are design judgments and recommendations, not measured defects by themselves. The source findings below provide their mechanical counterparts. System typography and the near-black surface fit a native hardware utility; no generic restyling or web-specific typography mandate is proposed.

## Inferred system

[Theme.swift](https://github.com/Somafet/qnotch/blob/ffe496d6585652d2ef6f38c15056705c9ba83867/src/QNotch.Mac/Sources/QNotchMac/Shell/Theme.swift#L6) is the execution layer: surface `#0B0B0D`, card `#17171C`, primary text `#F4F4F7`, secondary `#A1A1AD`, tertiary `#6F6F7B`, with the system accent. AppKit system typography and SF Symbols are used. The panel host uses 12-point side insets. Shared Home CardView titles use 12-point semibold with a 14-point inset. No separate design-token document was found under docs or .claude.

## Mechanical findings

| Priority | Finding | Evidence and rule | Proposed response |
| --- | --- | --- | --- |
| High | Populated Search needs 320pt in a roughly 308pt host | Source dimensions; supplied search screenshot supports clipping. `rule/none`: native content-fit geometry | Fixed field + bounded scrolling results; capture actual frames before final diagnosis |
| Medium | Tab headings have no shared position or type scale | Source inventory below. `rule/alignment-consistent`, `rule/wayfinding-present` | One header contract, with explicit exceptions |
| Medium polish | Short CPU group floats inside a wing sized for the fuller opposite group | Supplied collapsed screenshot + centered layout formula. `rule/alignment-consistent` | Shared outer gutters |
| Medium | Search handles Return for the first hit, with no selected-result/arrow navigation state | Source-only. `rule/search-keyboard-navigable` | Selected result, Up/Down, scroll into view |
| Investigate | Tiny stat captions use 9pt | Source-only. Native legibility coverage gap; web `caption-min-12px` is not directly applicable | Inspect at native scale before choosing a minimum |

Physical-notch activation remains a user-reported interaction gap pending native pointer testing. Segment-specific opening and hiding Search are enhancement proposals. Timer already has a module-disable switch; it is not a missing capability.

## Heading inventory at the source baseline

Coordinates below are relative to tab content, not the global display. Source layout is not a substitute for screenshot measurements.

| Surface | Current heading / starting element | Source location under Sources/QNotchMac |
| --- | --- | --- |
| Home cards | Shared 12pt semibold title, inset14 | Shell/Controls.swift:118–129 |
| Search | Field at top; no page title | Shell/PanelView.swift:136–164 |
| Media | No page title; track title22pt, body inset20 | Modules/Media/MediaModule.swift:282–317 |
| Timer | Focus timer15pt semibold beside dial; title x194, group vertically centered | Modules/Timer/TimerModule.swift:248–287 |
| Clipboard | Filter chips at top; no page title | Modules/Clipboard/ClipboardViews.swift:53–71 |
| AI | Usage / Apps14pt semibold, top/left0 in scroll document | Modules/Ai/AiViews.swift:292–309 |
| Files | Files or count13pt semibold, top0 | Modules/FileTray/FileTrayViews.swift:57–123 |
| Notifications | Notifications13pt semibold, top0 | Modules/Notifications/NotificationsViews.swift:82–94 |
| Agents | Optional Today summary11pt tertiary, hidden at zero tokens; no stable page title | Modules/Agents/AgentsViews.swift:33–75 |
| Scheduled | Launch agents13pt semibold, top0 | Modules/Scheduled/ScheduledModule.swift:213–225 |

## Proposed header contract

Use a shared tab header aligned to the host's existing leading edge, with a stable baseline and height. The implementation adopts the proposed 14pt semibold, 28pt row height and 12pt separation from the body. Put actions in a trailing slot where they fit; keep longer filters/context in the body. Keep long/localized titles from displacing actions. Avoid double insets in scrolling content.

Use the tab's accessible title consistently: Media, Timer, Clipboard, AI, Files, Notifications, Agents and Scheduled tasks. Track title, Focus timer and Launch agents remain descriptive body headings where useful. Home may retain its shared card headings; Search may deliberately use its field as the primary landmark if that exception is documented and labeled. Do not force every content mode into the same body layout.

## Acceptance criteria from the original proposal

- Capture every tab at one display scale and settled window size; annotate title origin/baseline, action row and body origin. Shared headers match within 1 point after rounding.
- Review empty, populated, loading, unavailable/error, long/localized text and filtered states. Title placement does not depend on token totals, item count, or selected content.
- Verify scrolling keeps headers predictable and all actions reachable; first/last rows never disappear behind fixed chrome.
- VoiceOver exposes a useful named landmark and focus order; keyboard users can discover and activate tabs, filters and actions.
- Check reduced motion, tab reordering/hiding, all optional features off, notched and non-notched displays, and scaling/small display bounds.
- Preserve existing Home card title alignment. Inspect screenshots after the native build and smoke run; source-only checks cannot approve this UI change.

## Evidence limits and next step

The two user screenshots establish collapsed-wing spacing and the reported populated-search clipping. Other tabs have source-only evidence and need native screenshots before any claim that every title has been visually checked. The originals include unrelated personal desktop content and are intentionally not published in this proposal.

At review time, full Xcode was unavailable; fresh native captures were pending and empty Search snapshots missed the overflow case. The review above is historical evidence and an acceptance contract, not release approval. See Implementation follow-through for the implemented header scope and its current validation.
