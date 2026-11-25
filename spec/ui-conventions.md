# Cross-platform UI conventions

Both apps build the same product with native controls. When a feature exists on both platforms, every difference between the two belongs to one of three kinds:

| Kind | Rule | Examples |
| --- | --- | --- |
| **Product contract** | Must match | Which controls exist, when they show, hide or are disabled, what they do, the order and placement of actions, and the wording (with the platform terms below swapped in) |
| **Platform look** | Follow the platform | Control types, fonts, sizes, spacing, grouping and dividers, button capitalization |
| **Platform capability** | Record it | A feature or concept that exists on one platform only |

A difference that is not a platform term or listed under [Deliberate platform differences](#deliberate-platform-differences) counts as a contract difference. Fix it, or add it to that table with the reason. Contracts for specific surfaces live next to this file, for example [Settings](settings.md) and [Drop screen](drop-screen.md).

## Platform terms

Shared wording uses these placeholders. Everything else in a contract's quoted text is the same on both platforms.

| Placeholder | Windows | macOS |
| --- | --- | --- |
| `{surface}`, the collapsed QNotch at the top of the display | pill | notch |
| `{escape}` | Esc | Escape |

Button labels follow each platform's capitalization: sentence case on Windows ("Apply and restart"), title case on macOS ("Apply and Restart").

## Shared patterns

- **Caption strip.** A tab can start with one muted line. State or hints go on the left ("4 devices · Updates automatically"), and the strip's actions go on the right. When a notice or empty state takes the place of the tab's content, the text goes empty and the actions stay. Terminal and Taildrop use it.
- **Link buttons.** These are small text actions with no fill at rest, in the accent color, with a lighter accent on hover. They are implemented as `LinkButton` on Windows and `HoverButton` with style `.link` on macOS. Do not make a grey link.
- **Action placement.** Actions sit at the trailing (right) end of their row, strip or banner.
- **Hide, don't disable, options that don't apply.** An option that does nothing in the current mode is hidden. It comes back as soon as the mode changes, and its saved value is kept. Disable only an option that applies but cannot be used right now, such as Share usage data when the environment turns telemetry off.
- **Descriptions match the current mode.** A description says what the option does now. When a mode change changes that, swap the text; don't add "Not used with …".
- **Identifiers.** When both platforms give a control an accessibility identifier that checks or the debug channel use, it is the same string on both (for example `open-on`). [Diagnostics](diagnostics.md) lists the identifiers that checks rely on.

## Deliberate platform differences

| Area | Windows | macOS | Kind |
| --- | --- | --- | --- |
| Settings layout | Flat rows, no dividers | Grouped rounded boxes with dividers, like System Settings | Look |
| Settings, General | Notch position (one spot or one per app, and Reset) | Show menu-bar icon | Capability |
| Where a moved notch stays ([Notch position](notch-position.md)) | One spot, or a spot per app | One spot per display | Capability |
| Moving the notch | Every display | Only displays without a camera housing | Capability |
| Open hovered feature | Not yet | Available | Capability |
