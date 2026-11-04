# Drop screen

When the user drags files onto the notch, the shell shows the drop screen. It lists every place the files can go, and the user drops them on one. Both platforms follow this contract. Each uses its own controls and drag APIs.

## Drop sources

A module registers drop sources through its module context. A module that is turned off registers nothing, and the shell names no module.

| Field | Meaning |
| --- | --- |
| `id` | Unique source id; part of each tile's identifier |
| `title`, `glyph` | Heading of the source's group |
| `order` | Group order, lowest first |
| `targets(files)` | The source's tiles for the dragged items |

`targets` gets the dragged paths. The list is empty when the source app has not named them yet. `targets` runs on the UI thread every time the screen shows, and again while it is shown. It filters state the module already holds: no network, no reading file contents, no processes. Checking whether a dragged path is a folder is allowed. A source that returns no targets is left out.

A target has an `id`, a `title`, an optional `subtitle`, a `glyph`, `enabled`, and `drop(files)`. A disabled target shows its subtitle as the reason it is off.

## Behavior

- **When it shows:** a file drag enters the collapsed pill or the open panel, at least one source is registered, and the notch is not in game mode. The shell opens the panel with the normal hover dwell, and the screen covers the header, the tabs and the tab content. A drag that starts inside the panel, such as a File tray item, gets the screen too.
- **Header:** "Drop <name>" for one item, or "Drop N items" for several. Under it, a muted line: "Choose where they go".
- **Groups:** one per source, in `order`. Each group has a small heading with the source's glyph and title, then its target tiles in a wrapping row. If no source has a target, the screen shows "Nothing can take these files right now".
- **Tiles:** an enabled tile highlights with an accent border while files are over it, and accepts the drop as a copy. A disabled tile is dimmed and refuses the drop. A drop outside every tile is refused and does nothing.
- **Drop:** the screen closes, then the target's `drop(files)` runs. The module decides what to show next.
- **No drop:** the screen closes when the drag leaves the window or is cancelled. A short debounce (about 150 ms) stops it flickering while the pointer moves between tiles. The normal leave delay then closes the panel if the pointer is outside it. While the drag is over the screen, the panel stays open, whichever element handles the drag events.
- **Fresh state:** the screen asks its sources again while it is shown (Windows: every 400 ms, during the drag only) and rebuilds only when a target changed. A source whose state was still loading when the drag began can catch up this way.

## Built-in sources

| Source | Order | Targets |
| --- | --- | --- |
| `files`, File tray | 10 | `add`, "Add to tray": "Keep them within reach". Disabled with "Already in the tray" when every dragged item is already in the tray. Its drop adds the items and selects the Files tab. |
| `taildrop`, Taildrop | 20 | One tile per device (id: its stable id) while Tailscale is ready. The subtitle is the device's OS. A device is disabled with "Offline" when it is offline, "Busy sending" while a send runs, and "Folders can't be sent" when every item is a folder. When Tailscale is not ready, there is one disabled tile titled with the state ("Tailscale is not running", "Sign in to Tailscale", ...). Its drop sends the files and selects the Taildrop tab. |

## Accessibility and diagnostics

- **Accessibility:** the screen root has the identifier `drop-screen`. Each tile is a button with the identifier `drop-<source>-<target>` and the name "<target title>, <source title>". A disabled tile reports that it is not enabled. While the screen shows, the header and tabs underneath are hidden from the accessibility tree.
- **Snapshot:** `panel-drop.png` shows the screen for two demo items, `holiday-photos.zip` and `trip-notes.pdf`, with every source's demo targets.
- **Smoke check:** `drop-screen` simulates a file drag over the collapsed notch. It checks that the panel opens on the drop screen with a named tile for every source that has targets, and that the tabs are hidden. When the drag ends without a drop, the screen must go away and the panel must close again.
