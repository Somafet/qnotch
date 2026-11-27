# Settings

This file defines the settings rows both platforms share. The layout follows each platform, as described in [UI conventions](ui-conventions.md). Quoted labels and descriptions are exact on both platforms once the platform terms (`{surface}`, `{escape}`) are swapped in. Text marked *platform wording* only has to say the same things; its reasons can differ.

## General: language

Windows only for now. The Language row is defined in [Interface language](localization.md#settings-language).

## General: opening and closing the panel

On Windows these rows are on the General page. On macOS they are the Panel group of General.

| Row | Control | Shown | Description |
| --- | --- | --- | --- |
| Open on | Pop-up with Hover and Click; default Hover; identifier `open-on` | Always | *Platform wording.* Says what each choice does and what closes a panel opened by a click: a click outside, `{escape}` or the hotkey. |
| Hover delay | Slider, 0–600 ms, step 10, default 120 | Always | Hover: "How long the pointer must rest on the `{surface}` before the panel opens."<br>Click: "How long files dragged onto the `{surface}` rest there before the panel opens." |
| Open hovered feature | Switch, default off; identifier `hover-opens-segment` | Hover only | macOS only for now. See [Deliberate platform differences](ui-conventions.md#deliberate-platform-differences). |
| Close delay | Slider, 100–1500 ms, step 50, default 400 | Hover only | "How long after the pointer leaves before the panel closes." |
| Keep panel open | Switch, default off; the same setting as the pin in the panel header | Always | *Platform wording.* The panel stays open when the pointer leaves, until the user closes it. |

Behavior:

- A change to Open on applies at once. The Hover only rows hide or show immediately, and the Hover delay description swaps.
- A hidden row keeps its saved value, and that value is still used where it applies. With Open on set to Click, a panel opened by a file drag or by a feature (a timer or a notification) still closes after the close delay once the pointer is outside it.
- Storage: Windows saves `OpenOn` (`"Hover"` or `"Click"`) in `general.json`. macOS saves `openOnClick` there and carries Windows' `OpenOn` form in setup codes.

## General: notch position

Windows only. The Notch position row is defined in [Notch position](notch-position.md#settings-notch-position-windows).

## Known gaps

These are places where the current apps don't follow this file yet. Fix them the next time you change the row.

- Close delay, Windows: "Grace period after the pointer leaves before the panel closes."
- Keep panel open: the two platforms say different things. Windows says "Pinned: the panel stays open when the pointer leaves." macOS lists what closes it (Escape, the pin, the toggle hotkey). Pick one shared text, then put it in this file.
