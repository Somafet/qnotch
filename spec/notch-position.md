# Notch position

This file defines how the user moves the `{surface}` sideways and where it stays afterwards. Platform terms (`{surface}`, `{escape}`) are in [UI conventions](ui-conventions.md#platform-terms).

## Which displays

- **Windows:** every display. QNotch always draws its own `{surface}`.
- **macOS:** only displays without a camera housing. On a display where the notch wraps the camera housing, it never moves. No drag starts there, a double-click does nothing, and the press goes to whatever is under it as usual.

## Moving it

- **Handles.** There are two:
  - the collapsed `{surface}`;
  - the empty part of the open panel's header: the strip across the top of the panel above the content, including the space between and around the header's controls. Tabs, buttons, cards and other controls in the panel keep their own clicks and drags.
- **Start.** A drag starts when a press on a handle moves sideways by more than 5 points (DIPs on Windows). A press that ends without moving that far is a plain click. On the collapsed `{surface}`, that opens the panel the way a click does. In the header it does nothing.
- **Dragging the open panel.** The panel folds back into the `{surface}` the user is carrying. When the drag ends, the panel opens again only if Keep panel open is on. Otherwise it stays closed.
- **Release.** The `{surface}` keeps its momentum and springs into place. If it would land within 56 points of the center or of a display edge, it snaps to the center or flush with that edge. With reduce motion on, it jumps straight to its final spot.
- **Double-click** on either handle centers it and saves that spot.
- **Game mode.** Nothing moves while the game bar shows.
- **Analytics.** Each drop and each centering double-click records `shell`/`move_notch` with surface `ui`. A press that does not become a drag records nothing.

## Where it stays

- **macOS:** one spot per display, whatever app is in front. Stored as `pillOffsets` in `general.json`, keyed by display ID. A centered display has no entry.
- **Windows:** the Notch position setting below chooses between one spot for every app and a separate spot for each app.

## Settings: Notch position (Windows)

This row is on the General page, after Monitor. The Mac has no Notch position row; see [Deliberate platform differences](ui-conventions.md#deliberate-platform-differences).

| Row | Control | Shown | Description |
| --- | --- | --- | --- |
| Notch position | Pop-up with "Same for every app" and "Each app has its own"; identifier `notch-position`. A Reset button follows it. | Always | Same for every app: "Drag the pill sideways to move it out of the way, or onto another display. It stays there whatever app is in front. Double-click it to center it again."<br>Each app has its own: "Drag the pill sideways to move it out of the way, or onto another display. Each app keeps its own spot, and the pill moves there when that app comes to the front. Double-click it to center it again." |

Behavior:

- **Default.** A new install uses Same for every app. An install that already has saved app spots when it first meets this setting uses Each app has its own, so nobody's layout changes on update.
- **Changing the choice** applies at once, and the description swaps.
  - Switching to Same for every app keeps the pill where it is now. If it is still sliding, it finishes the slide, and the spot it lands on becomes the one spot.
  - Switching to Each app has its own moves the pill to the saved spot of the app in front, or the center if that app has none. Saved app spots are kept while the other choice is active.
- **Reset** centers the pill. With Each app has its own, it also forgets every app's spot. Analytics: `settings`/`reset_positions`. Changing the choice records `settings`/`change` with target `notch_position`.
- **Storage.** `general.json` holds:
  - `NotchPosition`: `"Everywhere"` or `"PerApp"`. Missing means it was never decided; the app decides it at startup as described under Default.
  - `NotchX`: the one spot, in DIPs from the display's center, where ±10000 means flush with that edge. Missing means centered.
  - `NotchSpots`: the per-app spots, keyed by process name and stored the same way as `NotchX`.

  All three are local. Setup codes do not carry them.

## The per-app hint (Windows)

The first time the pill moves on its own because a different app came to the front while Each app has its own is active, the collapsed pill briefly shows a peek:

- Text: "Each app keeps its own pill spot · Settings". The glyph is the Settings glyph in the accent color, and it shows for 6 seconds.
- It shows only when the pill is collapsed and not in game mode. If it can't show, it waits for the next such move.
- It shows once per install. Changing the Notch position choice also counts as seeing it.
- Storage: `NotchSpotHintShown` in `general.json`. It is local and setup codes do not carry it.

## Known gaps

- Carrying the `{surface}` onto another display: Windows does this. On macOS the dragged notch stays on its own display and settles flush with the edge.
