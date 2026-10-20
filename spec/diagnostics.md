# Diagnostics

The developer tooling both apps provide so people and agents can render, check, measure and drive QNotch without guessing. Both platforms implement it natively (WPF on Windows, AppKit on the Mac) from this contract. Flags, file names, the outline format and the debug protocol are shared. How each platform renders, finds controls or measures follows its own APIs.

Nothing here is user-facing. None of these modes make network requests, read or write the credential store (Windows Credential Manager, the Mac Keychain), touch login items or update settings, or show the welcome tour by themselves.

## Modes

| Flag | What it does | Report |
|---|---|---|
| `--snapshot <dir>` | Renders every view to PNG with a text outline, then exits. Render-only: no interaction checks. | `snapshot.txt` |
| `--smoke-test <dir>` | Everything `--snapshot` writes, then drives the real shell through scripted interactions and checks the results. | `smoke.txt` |
| `--measure <dir>` | Measures startup, idle CPU and memory, then exits. | `performance.json` |
| `--debug-control` | Starts the interactive app with the [debug channel](#debug-channel) open. | none |

Shared options:

- `--data-dir <absolute path>` replaces the whole data root (settings, logs, the instance lock or mutex). The existing variables keep working: `QNOTCH_DATA_DIR` (Windows) and `QNOTCH_MAC_DATA_DIR` (Mac). `--data-dir` wins when both are given.
- `--only <pattern>` (snapshot and smoke-test): renders only views whose file name without `.png` matches. `*` matches any run of characters; separate several patterns with commas (`--only "tab-*,settings-general"`). The report still ends in `done`.
- `--appearance light|dark` (snapshot and smoke-test): forces the appearance for the run. Default: the system's. Windows keeps its legacy positional `light` argument as an alias.

`--snapshot`, `--smoke-test` and `--measure` never take the single-instance lock, so they run next to a normal instance. Without `--data-dir` they use a fresh temporary data root and delete it on exit. They use demo data (a connected GitHub account, a chosen place, sample clipboard entries, sample files) and keep secrets in memory. They skip or complete every animation, so images show the settled state. Exit code 0 when the report ends in `done`, 1 otherwise.

## Snapshot files

Every PNG is rendered at 2x and has an outline with the same base name and `.txt`. Names are built from registry ids, so a new tab, card or settings section gets its snapshot without changing the tool.

| File | View |
|---|---|
| `pill.png` | The collapsed notch, idle |
| `pill-<state>.png` | The collapsed notch in a state: `peek`, `running`, `capture`, `waiting`, `agent`, `game` |
| `tab-<tab id>.png` | The open panel on each registered tab, `tab-home.png` included |
| `tab-home-edit.png` | Home in edit mode |
| `card-<card id>.png` | Each Home card on its own |
| `settings-<section id>.png` | Each settings section or page (`module.` prefixes dropped) |
| `onboarding-<step>.png` | Each welcome tour step: `welcome`, `open`, `features`, `connect`, `finish` |

A platform may write more views under other names (`gamebar-corner.png`, `files-drop.png`): lowercase letters, digits, `.`, `_` and `-`. Each still needs its outline. A view a platform does not have (no game bar, no such tab) is simply absent; a registered tab, card or section without its PNG is a failure. Other diagnostic text (placement details, per-check logs) uses `.log`, so every `.txt` besides the report is an outline.

### Report

`snapshot.txt` and `smoke.txt` are plain text, one entry per line:

```
version: 0.1.0
pill: ok
tab-timer: ok
check hotkey-toggle: ok
check game-mode: skip: no game detection on this display
FAILED: tab-media: the panel did not show the Media tab
done
```

- `<view>: ok` for each written view, `check <name>: ok` for each smoke check, `check <name>: skip: <reason>` for a check the platform cannot run. Free-form `<key>: <value>` lines are allowed (`version`, `startup_seconds`).
- With `--only`, the report has an `only: <patterns>` line.
- Any `FAILED: …` line fails the run. The last line is `done` only when every view and check passed.

`node scripts/check-snapshots.mjs <dir>` validates a snapshot or smoke directory on either platform: the report ends in `done` with no `FAILED` line, every PNG has an outline and every outline a PNG, file names follow the table above, the required views (`pill`, `tab-home`, `tab-home-edit`, at least one `settings-*` and every `onboarding-*` step) are present unless the report has an `only:` line, and every outline parses. Both CI jobs run it on their artifacts.

## Outline format

An outline is what an agent reads instead of a screenshot: the visible, meaningful elements of a view with their text, accessible name, identifier and state, nested by containment. UTF-8, `\n` line endings, two spaces of indentation per level.

```
[Tab] "Home" #tab-home selected
[Tab] "Timer" #tab-timer
"Focus"
"25:00"
[Button] "Start" #timer-start
[Toggle] "Sounds" #timer-sounds checked
[Slider] "Volume" 40 of 100
[Field] "Search" #search-field value="wea"
[Item] "Weather" selected
  "Budapest"
  "12°"
```

A line is either static text or a control:

```
text    = '"' chars '"'
control = '[' Role ']' [' "' name '"'] [' #' id] [' ' value] {' ' state}
```

- **Roles**: `Button`, `Toggle` (switches, checkboxes, toggle buttons), `Tab`, `Field` (editable text), `SecureField` (contents never written), `Slider`, `Progress`, `PopUp` (pop-up buttons, combo boxes), `Item` (list, table or collection rows), `Link`. Anything else is not a control line, though its text and children still appear.
- **name**: the accessible name (`AutomationProperties.Name`, `accessibilityLabel`), else the visible title, else the tooltip. Omitted when there is none, which the smoke test treats as a failure for interactive controls.
- **id**: the stable identifier (`AutomationProperties.AutomationId`, `NSUserInterfaceItemIdentifier`). Ids are kebab-case and shared across platforms where the concept is shared (see [Identifiers](#identifiers)).
- **value**: `<n> of <max>` for sliders and progress (up to two decimals); `value="…"` for fields and pop-ups.
- **states**, in this order when present: `checked`, `selected`, `focused`, `disabled`.
- **Escaping**: inside quotes, `\` becomes `\\`, `"` becomes `\"`, a line break becomes `\n` and a tab `\t`.
- **Left out**: hidden or zero-size elements, elements scrolled fully out of view, scroll bars, empty text, icon-font glyphs and SF Symbol images without a label, and pure layout containers (they add no line; their children keep the parent's depth).
- Text that is a control's own title is not repeated as a child line.

## Identifiers

These ids are the same on both platforms, so outlines, smoke checks and debug commands work unchanged:

| Id | Element |
|---|---|
| `pill` | The collapsed notch surface |
| `panel` | The open panel's root |
| `tab-<tab id>` | A tab button in the panel header |
| `card-<card id>` | A Home card's container |
| `search-field` | The search box |
| `panel-pin` | Keep panel open |
| `open-settings` | The panel's Settings button |
| `settings-nav-<section id>` | A settings sidebar or section entry |
| `feature-<module id>` | A feature switch (Settings, Features and the tour) |
| `onboarding-<step>` | A welcome tour step's root |
| `onboarding-primary`, `onboarding-back`, `onboarding-skip` | The tour footer buttons |

Other controls should get kebab-case ids prefixed with their module or area (`timer-start`, `updates-check`) when a check or an agent needs to reach them.

## Smoke checks

`--smoke-test` reports each check as `check <name>: ok`, or `skip: <reason>` where the platform has no such behavior. The shared names:

| Check | Passes when |
|---|---|
| `placement` | The surface sits where it should against the display edge (and the camera housing on the Mac) |
| `hover-keeps-focus` | Hovering opens the panel without taking keyboard focus from the foreground app |
| `hotkey-toggle` | The toggle hotkey's action opens the panel with keyboard focus; pressed again it closes |
| `hotkey-search` | The search hotkey's action opens Search with the cursor in `search-field` |
| `escape-collapses` | Escape closes an open panel |
| `module-disabled` | A turned-off module is never constructed and has no tab, card or segment |
| `module-toggle` | Turning a module off and on stops and restarts it |
| `edit-mode` | Edit mode holds the panel open; a card drag saves its new place |
| `pin` | Keep panel open survives the pointer leaving |
| `notify-cli` | The `notify` command posts a toast and `--wait` returns the chosen action |
| `notify-transport` | The local transport (pipe or socket) accepts a request and answers |
| `agents-hook` | An agent hook event updates the Agents board |
| `game-mode` | Forced game mode stops the panel opening and shows the game wings or bar |
| `accessible-names` | Every interactive control in every view's outline has a name |
| `onboarding` | The tour does not open by itself; opened on demand it steps through every step, Return continues, Esc skips |
| `debug-channel` | With `--debug-control`, `ping`, `state`, `select-tab` and `outline` answer as documented |

A platform may add its own checks under other names.

## Measure

`--measure <dir>` writes `performance.json`, a flat JSON object. Required keys:

| Key | Meaning |
|---|---|
| `platform` | `Windows` or `macOS` |
| `app_version`, `source_revision`, `source_dirty` | What was measured |
| `os`, `architecture`, `hardware_model`, `physical_memory_bytes` | Where |
| `method` | How CPU and memory were sampled, in words |
| `startup_seconds` | Process start to the surface being shown |
| `interval_seconds`, `state` | The measured interval and the panel state during it |
| `cpu_percent_one_core` | CPU over the interval, as a percentage of one core |
| `resident_bytes_start`, `resident_bytes_end` | Resident memory (working set on Windows) at the interval's ends |
| `limits` | An array of `{ "name", "limit", "measured", "ok" }` for each hard limit the platform documents |

Platforms add their own keys (private bytes, wakeups, draw counters). The run fails (exit 1) when any `limits` entry is not `ok`.

## Debug channel

A local control channel for driving a running instance: read its state, switch tabs, press controls, type, take snapshots and outlines. It exists so agents can check the real app with real windows.

**Off unless asked for.** The channel opens only when the app is started with `--debug-control`. Such a run is otherwise the normal interactive app (network, credential store and updates as usual) except that the welcome tour does not open by itself; use the `onboarding` command. It is never opened by `--snapshot`, `--smoke-test` (which uses it internally only when checking `debug-channel`) or `--measure`, and never because of a setting.

**Transport.** Local to the user only; no network listener.

- Windows: the named pipe `\\.\pipe\QNotch.Debug`, or `QNotch.Debug.<QNOTCH_INSTANCE>` when that variable is set, created with `PipeOptions.CurrentUserOnly`.
- Mac: the Unix socket `debug.sock` in the data root, mode 0600, removed on quit.

**Protocol.** UTF-8 JSON, one object per line each way. A connection can send several requests; each gets exactly one response, in order. Requests over 64 KB are refused.

```
→ {"id":1,"cmd":"select-tab","args":{"id":"timer"}}
← {"id":1,"ok":true,"result":{}}
→ {"id":2,"cmd":"press","args":{"id":"nope"}}
← {"id":2,"ok":false,"error":"no visible control with id nope"}
```

`id` is echoed back unchanged and may be omitted. Commands run on the UI thread and respond after the UI has settled (animations complete, layout done), so a following `outline` or `snapshot` sees the result.

| Command | Args | Result |
|---|---|---|
| `ping` | | `{ "platform", "app_version", "pid", "data_dir" }` |
| `state` | | See below |
| `open` | `tab?` | Opens the panel with keyboard focus, optionally on a tab |
| `close` | | Closes the panel |
| `select-tab` | `id` | Opens the panel if needed and selects the tab |
| `settings` | `section?`, `close?` | Opens Settings (on a section) or closes it |
| `onboarding` | `close?` | Opens the welcome tour as Settings does, or closes it |
| `outline` | `window?` | `{ "text" }`: the outline of `panel` (default), `pill`, `settings` or `onboarding` |
| `snapshot` | `path`, `window?` | Writes a PNG and its outline to an absolute `path` ending in `.png`; `{ "path" }` |
| `press` | `id` | Activates the visible, enabled control with that id: clicks a button, flips a toggle, selects a tab or item. Refuses pop-ups, whose menus would block; set them with `key` |
| `type` | `text`, `id?` | Focuses the field `id` (or keeps the current focus) and inserts the text |
| `key` | `name`, `modifiers?` | Sends a key to QNotch's key window. `name`: `Escape`, `Return`, `Tab`, `Space`, `Up`, `Down`, `Left`, `Right`, `Backspace` (erases backwards: the Mac Delete key), `Delete` (erases forwards) or one character; `modifiers`: any of `ctrl`, `alt`, `shift`, `cmd` (`cmd` maps to the Windows key on Windows) |
| `hotkey` | `action` | Runs a global hotkey's action without the OS hotkey: `toggle`, `search`, `game-mode` |
| `game-mode` | `mode` | `auto`, `on` or `off` for the session |
| `quit` | | Responds, then quits |

`state` returns:

```json
{
  "panel": "open",
  "tab": "timer",
  "keyboard": true,
  "edit_mode": false,
  "pinned": false,
  "game_mode": "auto",
  "modules": [{ "id": "timer", "enabled": true, "running": true }],
  "windows": [{ "id": "panel", "visible": true, "frame": { "x": 640, "y": 0, "width": 760, "height": 430 } }]
}
```

`panel` is `collapsed` or `open`; `frame` is in screen points (DIPs on Windows) with the origin at the top left of the primary display on both platforms. `windows` lists `pill`, `panel`, `settings` and `onboarding` when they exist; where the pill and panel are one window (the Mac), both entries appear and the one not shown has its settled layout frame. "Settled" means layout is done and no finite animation is running in a visible window, checked on consecutive frames, with a 3-second cap; timers (hover delays) are not waited for.

**Command line.** `QNotch debug <cmd> [--<arg> <value>…]` sends one request and prints the response's `result` as JSON on stdout (or `{"error": …}` on stderr). It finds the instance the same way the app does: `--data-dir`/`QNOTCH_MAC_DATA_DIR` on the Mac, `QNOTCH_INSTANCE` on Windows. Exit codes: 0 ok, 1 the command failed, 3 no instance with the channel open, 4 bad usage.

The channel can read whatever QNotch shows (clipboard history, notifications) and press any control. That is no more than the same user can already do, but it is why it stays off by default and never listens beyond the user.
