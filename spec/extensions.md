# Extensions

Status: draft. Nothing here is implemented on either platform yet.

An extension is a program the user installs that puts content into QNotch: a tab, a Home card or a small segment in the pill, glance strip or game bar. QNotch hosts and draws the content, decides when it is visible and forwards input. The extension, called the *provider*, does all the domain work: fetching data, holding a connection, rendering a remote screen. QNotch ships nothing specific to any one extension.

This contract is shared. The manifest, the messages and their semantics are the same on Windows and the Mac, so a provider written for one platform runs on the other with no change beyond its own domain work (and, for pixel surfaces, the [platform transport](#platform-transport)).

## Scope of protocol 1

Protocol 1 is the manifest, the process lifecycle, the control channel and `view` content. That covers every slot, including segments, and almost every status use case.

Pixel surfaces (the `surface` kind) are specified in [Pixel surfaces](#pixel-surfaces) so the design stays coherent, but they belong to the next protocol revision. They are a negotiated capability, offered through an optional `hello` field (see [Capabilities](#capabilities)), and neither platform implements them before `view` ships on both.

## Goals and non-goals

Goals:

- Any user-driven content, from a status line to (with pixel surfaces) an interactive remote desktop, without a QNotch change per use case.
- The shared product principles in [README.md](README.md) still hold: hidden content does no work, memory is bounded, missing data has an explicit unavailable state, and focus is never taken without a user action.
- A crashing, hanging or misbehaving provider cannot take down, freeze or slow the notch.
- Nothing runs unless the user turned that specific extension on, on this computer.

Non-goals for protocol 1:

- Loading code into the QNotch process (DLLs, dylibs, scripts in an embedded runtime).
- HTML or web views.
- Installing, updating or sharing extensions. The user copies a folder; setup codes never carry extensions or their enablement.
- Clipboard, drag and drop, file drops, sounds and hotkeys for extensions.
- Notifications through the control channel. A provider runs as the user and posts notifications through the existing command line, named pipe or HTTP transports ([notifications](../docs/notifications.md)), so the extensions host stays independent of the Notifications module.
- Providers that QNotch did not start. A provider can itself accept data from other scripts if the user wants that.

## Content kinds

Each manifest lists one or more *surfaces*. A surface is one of two kinds:

| Kind | Who draws | Slots | Use it for |
| --- | --- | --- | --- |
| `view` | QNotch, with native controls and the current theme, from an element tree the provider sends | `tab`, `card`, `pill`, `glance`, `gamebar` | Status, values, lists, buttons, toggles |
| `surface` (next protocol) | The provider, into shared pixel buffers that QNotch shows | `tab`, `card` | Anything QNotch's elements cannot express: a remote screen, a canvas, a custom renderer |

Prefer `view`. It costs almost nothing, follows the theme and accessibility rules for free and works in every slot.

A `view` extension does not need a process at all: with no `run` entry, QNotch shows the views written to a file in the extension folder (see [File views](#file-views)).

## Installation and discovery

An extension is a folder in the data root:

- Windows: `%APPDATA%\QNotch\extensions\<id>\extension.json`
- Mac: `~/Library/Application Support/QNotch.Mac/extensions/<id>/extension.json`

`--data-dir` and the existing data-root variables move this folder with the rest of the data root. QNotch reads the manifests once at startup. Adding, removing or editing an extension applies on restart, like turning a module on or off (a file view's content is the exception: it updates live). A folder whose name differs from the manifest `id`, or whose manifest does not parse or validate, is listed in Settings, Extensions with the reason and is otherwise ignored.

## Manifest

```json
{
  "manifest": 1,
  "id": "ci-status",
  "title": "CI status",
  "description": "Builds and open pull requests for my projects.",
  "glyph": "build",
  "run": { "command": "node", "args": ["provider.mjs"] },
  "surfaces": [
    { "id": "status", "kind": "view", "slot": "tab", "title": "CI", "order": 75 },
    { "id": "badge", "kind": "view", "slot": "pill" }
  ],
  "start": "boot"
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `manifest` | yes | Manifest format version. This document defines `1`. |
| `id` | yes | `^[a-z0-9][a-z0-9-]{0,31}$`. Stable: it keys enablement, layout and settings. |
| `title` | yes | Shown in Settings and as the default surface title. At most 40 characters. |
| `description` | no | One line in Settings. At most 200 characters. |
| `glyph` | no | An icon name from the shared list (the [notification icon names](../docs/notifications.md#payload) plus `desktop`, `chart`, `puzzle`). Default `puzzle`. |
| `run` | no | What to start. Either `{ "command", "args", "cwd", "env" }` for every platform, or the same object under `windows` and `mac`. Absent: a [file view](#file-views), and every surface must be a `view`. Present but with no entry for this platform: the extension is listed as unavailable here. |
| `run.command` | yes | Absolute, relative to the extension folder (contains a path separator), or a bare name looked up on `PATH`. Started directly, never through a shell. On the Mac, apps started from Finder get a minimal `PATH`, so tools installed by a package manager need an absolute path. |
| `run.args` | no | Array of strings, passed as is. |
| `run.cwd` | no | Default: the extension folder. |
| `run.env` | no | Extra environment variables, string to string. |
| `start` | no | `visible` (default): start when a surface first becomes visible. `boot`: start right after the first frame. Required to be `boot` when any surface is in `pill`, `glance` or `gamebar`. |
| `stopWhenHiddenSeconds` | no | Stop the provider after all its surfaces have been hidden this long. It starts again when one becomes visible. Default `300`. `0` never stops it (the provider only gets `hidden`); a provider that must keep a session, such as a remote desktop, opts out this way. |
| `surfaces` | yes | 1 to 8 entries. |
| `surfaces[].id` | yes | `^[a-z0-9][a-z0-9-]{0,31}$`, unique within the manifest. |
| `surfaces[].kind` | yes | `view` or `surface`. A `surface` entry is valid in manifest 1 but is listed as unavailable until both sides support the [capability](#capabilities); the extension's other surfaces still work. |
| `surfaces[].slot` | yes | `tab`, `card`, `pill`, `glance` or `gamebar`; `surface` only in `tab` or `card`. |
| `surfaces[].title` | no | Tab label, card title or game bar toggle label. Default: the manifest `title`. |
| `surfaces[].order` | no | Default order in its slot. Default: after every built-in item. |
| `surfaces[].sizes` | no | Cards only: the card sizes it supports, from `small` and `medium`. Default `["small"]`. |

`start` and `stopWhenHiddenSeconds` are ignored without `run`. Unknown fields are ignored, so later manifest versions can add optional fields without bumping `manifest`.

Registered ids follow the existing conventions: tabs and cards are `ext.<id>.<surface>`, segments `ext.<slot>.<id>.<surface>`. These ids persist in tab order, card order, card sizes and game bar toggles exactly like built-in ones.

## Enablement and trust

An extension runs a program the user chose, with the user's rights. So:

- Every extension is off until the user turns it on in Settings, Extensions. The switch shows the exact command line that will run (resolved command, arguments and working folder), or "Shows view.json; runs nothing." for a file view.
- Enablement is stored locally (`extensions.json` in the data root) with a hash of the resolved `run` entry. If the command, arguments, working folder or environment change, the extension is off again until the user confirms the new command. Changing the program file itself does not reset it: the user owns that file.
- Enablement is never part of setup codes, and setup codes never carry manifests.
- A disabled extension is never started and registers nothing, like a disabled module.
- `--snapshot`, `--smoke-test` and `--measure` never start providers, whatever the settings say. Snapshots render a provider's surfaces as their placeholder, and render enabled file views from the data root they use (they run nothing), which is how view fixtures are rendered.
- The host itself is a module (`extensions`) that is on by default; with no enabled extensions it starts nothing.

Buttons and toggles in a `view` send an action to the provider; QNotch itself never opens a link or runs anything because of an extension's content. What the provider does with an action is the provider's business, the same way a script that posts a notification decides what to do with its answer.

## Process lifecycle

QNotch starts the provider with the manifest's `run` entry, its standard input and output as the [control channel](#control-channel) and its standard error captured to `logs/ext-<id>.log` (the last 256 KiB are kept). It sets these environment variables in addition to `run.env`:

| Variable | Value |
| --- | --- |
| `QNOTCH_EXTENSION_ID` | The manifest `id`. |
| `QNOTCH_EXTENSION_DIR` | Absolute path of the extension folder. |
| `QNOTCH_PLATFORM` | `windows` or `mac`. |
| `QNOTCH_VERSION` | The QNotch version. |

Rules:

- One provider process per extension, serving all of its surfaces.
- The provider must send `ready` within 10 seconds of `hello`; otherwise QNotch stops it and shows it as unavailable.
- To stop a provider, QNotch sends `shutdown`, waits up to 2 seconds for it to exit, then ends it and every process it started. Windows puts the provider in a job object that kills its tree on close, reusing Terminal's process ownership; the Mac starts it in its own process group with `posix_spawn` and sends SIGTERM, then SIGKILL after 2 seconds.
- QNotch stops every provider on quit, when its extension is turned off, after `stopWhenHiddenSeconds`, and when the provider breaks the protocol (see [Control channel](#control-channel)).
- When a provider exits unexpectedly, its tab and card surfaces show the unavailable placeholder with the exit code and a Restart button; its segments hide.
- Automatic restarts follow visibility. While one of the provider's surfaces is visible, QNotch restarts it after 1, 5 and 30 seconds. When none is, it restarts on the next `visible` instead (after any remaining part of that delay), so a crashed provider with hidden surfaces does no work. A `boot` provider's segments count as visible while their slot is shown. After three unexpected exits within 5 minutes the provider stays stopped until the user presses Restart.
- A provider that stops reading its input does not block QNotch. Writes to the provider are queued with a 1 MiB bound; when the queue is full, QNotch drops queued `pointer` moves first (pixel surfaces only), then stops the provider as unresponsive.

## Control channel

UTF-8 JSON, one message per line (`\n`, an optional `\r` before it is ignored), on the provider's standard input (QNotch to provider) and standard output (provider to QNotch). Providers should write logs to standard error.

- Every message is an object with a `type`. Messages about one surface carry `surface` (the surface `id`).
- A line is at most 1 MiB. Any legal `view` fits (see the [tree limits](#limits)).
- Blank lines, and lines whose first non-whitespace character is not `{`, are copied to the extension's log and ignored, so warnings a runtime prints to standard output do not stop the provider.
- A protocol error stops the provider: a line over the limit, a line starting with `{` that is not a JSON object with a string `type`, a message for an unknown surface, or (pixel surfaces) a frame for a buffer it does not hold.
- Unknown message types and unknown fields are ignored, in both directions. New optional behavior is added this way without a version bump.
- QNotch processes provider messages off the UI thread and applies their effect on it, coalesced. When several `view` messages for a surface arrive before QNotch next draws, only the latest is applied. Several `frame` messages are all copied but drawn once (see [Frames](#frames)).

### Handshake and version

```json
{"type":"hello","protocol":[1],"capabilities":[],"platform":"windows","version":"1.9.0","locale":"en-US","theme":{"appearance":"dark","accent":"#4C8DFF","reducedMotion":false},"surfaces":[{"id":"status","kind":"view","slot":"tab"},{"id":"badge","kind":"view","slot":"pill"}]}
{"type":"ready","protocol":1,"capabilities":[]}
```

`hello.protocol` lists the major versions QNotch speaks. The provider answers with the one it chose; a provider that supports none of them exits with an error on standard error. This document defines version `1`.

`theme` is sent again as `{"type":"theme", ...same fields}` when it changes. `view` surfaces follow the theme by themselves; the message is for providers that draw their own pixels or pick content by appearance.

### Capabilities

Additive features are negotiated rather than versioned. `hello.capabilities` lists the optional features this QNotch implements; the provider answers with the subset it uses in `ready.capabilities`. A feature is active only when both lists name it. Missing means an empty list.

| Capability | Adds |
| --- | --- |
| `surface` | [Pixel surfaces](#pixel-surfaces). Next protocol revision. |

### Messages

QNotch to provider:

| Type | Fields | Meaning |
| --- | --- | --- |
| `hello` | see above | First message. |
| `theme` | `appearance`, `accent`, `reducedMotion` | The theme changed. |
| `visible` | `surface` | The surface is on screen. |
| `hidden` | `surface` | The surface is off screen: stop any work only it needs. |
| `action` | `surface`, `id`, `value` | A `view` button was pressed (`value` absent) or a toggle changed (`value` true or false). |
| `shutdown` | | Exit now. |

Provider to QNotch:

| Type | Fields | Meaning |
| --- | --- | --- |
| `ready` | `protocol`, `capabilities` | Handshake answer. |
| `view` | `surface`, `root` | Replace a `view` surface's content. See [View elements](#view-elements). |
| `status` | `surface`, `state`, `message` | `state` is `ok`, `connecting` or `unavailable`. See [Placeholders](#placeholders). |
| `title` | `surface`, `text` | Change the tab label or card title for this session (at most 40 characters). |

The `surface` capability adds the messages listed under [Pixel surfaces](#pixel-surfaces).

### Placeholders

- A tab or card starts in `connecting` (the standard placeholder) until its first `view` or `status`. Any `status` other than `ok` shows the placeholder with `message` (at most 200 characters) instead of the content.
- A segment (`pill`, `glance`, `gamebar`) starts hidden and stays hidden until its first non-empty `view`, so enabled extensions never widen the pill with placeholders on boot. Any `status` other than `ok` hides it; the Settings row shows the message. An empty `stack` hides it again.

## View elements

A `view` message carries a tree of elements. QNotch draws it with its own controls, fonts and theme brushes, and diffs it against the previous tree by element `id` so unchanged elements cost nothing.

```json
{"type":"view","surface":"status","root":
  {"type":"stack","direction":"vertical","children":[
    {"type":"value","id":"build","label":"Build","value":"passing","level":"success","icon":"check"},
    {"type":"progress","id":"deploy","label":"Deploy","value":0.72},
    {"type":"list","id":"queue","items":[
      {"id":"pr-42","title":"Fix login","detail":"2 approvals","icon":"code","action":"open-pr-42"}
    ]},
    {"type":"stack","direction":"horizontal","children":[
      {"type":"button","id":"retry","label":"Retry"},
      {"type":"toggle","id":"auto","label":"Auto deploy","value":true}
    ]}
  ]}}
```

| Element | Fields | Notes |
| --- | --- | --- |
| `stack` | `direction` (`vertical` default, `horizontal`), `children` | Layout. Spacing comes from the theme. |
| `text` | `value`, `style` (`body` default, `title`, `caption`, `mono`), `level` | Wraps in tabs and cards; one line, trimmed, in segments. |
| `icon` | `name`, `level` | A shared glyph name. |
| `value` | `label`, `value`, `unit`, `icon`, `level` | A labelled value. `value: null` shows the unavailable dash, never `0`. |
| `progress` | `label`, `value` | `value` 0 to 1, or `null` for indeterminate. Indeterminate animation stops while hidden and with reduced motion. |
| `list` | `items`: `id`, `title`, `detail`, `icon`, `level`, `action` | Scrolls inside tabs. At most 200 items. A row with `action` is a button that sends `action` with that id. |
| `button` | `id`, `label`, `style` (`default`, `primary`, `danger`) | Sends `action`. |
| `toggle` | `id`, `label`, `value` | Sends `action` with the new value. QNotch shows the new value at once; the next `view` is the truth. |
| `image` | `path`, `alt` | A local PNG or JPEG, absolute or relative to the extension folder, at most 2 MB; decoded at the size shown. |
| `placeholder` | `icon`, `title`, `message` | The standard empty or unavailable state. |

- `level` is `info`, `success`, `warning` or `error` and maps to theme colors. There are no raw colors, fonts or sizes.
- Every interactive element needs an `id`, unique within the tree; `label` is its accessible name (`alt` for images).
- Segments (`pill`, `glance`, `gamebar`) accept only `stack` (horizontal), `icon`, `text`, `value` and `progress`, on one line, and no input. Their width is capped by the platform and content is trimmed to fit.
- Text wraps at word boundaries and breaks inside a word only when the word alone is wider than the line. Trimmed text ends with an ellipsis.
- While Home is in edit mode, buttons, toggles and list rows on cards are drawn disabled and send no `action`; views are still applied. The provider is not told.

### Limits

- At most 500 elements per tree, counting list items, nested at most 8 deep.
- `title`, `label` and list item `title` are at most 100 characters; `text.value`, `value.value` and list item `detail` at most 500. In segments every string is at most 40.
- All strings in one tree together are at most 128 KiB as UTF-8. With the element count this bounds a tree, escaping included, below the 1 MiB line limit.

A tree over a limit is rejected as a whole: the previous view stays and the error goes to the log and the Settings row.

### Parity

Two native renderers interpreting the same tree is where the platforms will drift. To keep them together:

- The element set above is closed for protocol 1. An element or field is added only when a sample provider needs it, together with its fixtures.
- Every element, every slot and every limit has a view fixture (see [Conformance](#conformance)) that both platforms render with `--snapshot`. Fixtures cover wrapping, trimming at each cap, `null` values, every `level` and the disabled edit-mode state.

### File views

An extension without `run` has no process and no lifecycle. QNotch shows the views in `view.json` in the extension folder, so a cron job or a Claude Code hook writing one file gives a status card or a pill segment.

```json
{"views":{"status":{"type":"stack","children":[{"type":"value","label":"Backups","value":"3 h ago","level":"success"}]}}}
```

- `views` maps surface ids to root elements, with the same element rules and limits as a `view` message. The file is at most 1 MiB.
- QNotch watches the file while the extension is enabled and re-reads it after a change, debounced by 250 ms. Changes while every surface is hidden are read when one next becomes visible.
- Write the file atomically: write a temporary file in the same folder, then rename it over `view.json`. A file that is missing, does not parse or breaks a limit keeps the last valid content; the Settings row and the log show the error.
- A surface with no entry follows the [placeholder rules](#placeholders): a tab or card shows the empty placeholder, a segment stays hidden.
- There is no one to receive actions, so buttons, toggles and list row actions are drawn disabled.

## Visibility and cadence

- `visible` and `hidden` follow what is actually on screen: the panel is open on that tab, the card is shown on Home, the segment's slot is shown. A tab that is selected while the panel is collapsed is hidden. A segment hidden only because its content is empty still counts as visible, so its provider can show it when it matters.
- Providers should do no periodic work for a surface while it is hidden. QNotch enforces this only by stopping hidden providers after `stopWhenHiddenSeconds` (and, for pixel surfaces, ignoring hidden frames).
- A `view` sent while hidden is applied, so the surface is current when it reappears; send views only when the content changed.

### Resources and measurement

- Provider resource use is advisory. Settings shows each running provider's CPU use and memory; QNotch enforces no CPU or memory limit. A platform may later add a local limit (a Windows job object memory limit) without changing this contract.
- The hard performance limits each platform documents cover the QNotch process only. The host's own work (reading the channel, applying views, copying frames) counts toward them; provider processes do not. `--measure` never starts providers, so `performance.json` never includes them.

## Pixel surfaces

Next protocol revision, behind the `surface` [capability](#capabilities). Nothing in this section applies until both `hello.capabilities` and `ready.capabilities` list `surface`.

A `surface` surface shows pixels the provider writes into buffers QNotch allocates. Pixel surfaces are meant for tabs and medium cards: a small card body is roughly 188 by 98 layout units on Windows, too small for most pixel content.

A pixel-surface manifest entry, for a remote desktop that keeps its session while hidden:

```json
{
  "manifest": 1,
  "id": "remote-pc",
  "title": "Work PC",
  "glyph": "desktop",
  "run": {
    "windows": { "command": "bin\\rdp-bridge.exe", "args": ["--profile", "work"] },
    "mac": { "command": "bin/rdp-bridge", "args": ["--profile", "work"] }
  },
  "stopWhenHiddenSeconds": 0,
  "surfaces": [{ "id": "screen", "kind": "surface", "slot": "tab", "title": "Work PC", "order": 75 }]
}
```

### Messages

QNotch to provider:

| Type | Fields | Meaning |
| --- | --- | --- |
| `buffers` | see [Buffers](#buffers) | Pixel buffers for the surface. |
| `consumed` | `surface`, `generation`, `buffer` | QNotch has finished reading a buffer. |
| `pointer` | see [Input](#input) | Mouse, pen or touch input. |
| `key` | see [Input](#input) | Keyboard input. |
| `text` | `surface`, `text`, `composed` | Text input after keyboard layout and composition. See [Input](#input). |
| `focus` / `blur` | `surface` | The surface got or lost the keyboard. |
| `input` | `surface`, `enabled` | Input to the surface was turned off (`false`) or back on (`true`). See [Edit mode](#edit-mode). |

Provider to QNotch:

| Type | Fields | Meaning |
| --- | --- | --- |
| `attached` | `surface`, `generation` | The provider has opened the buffers of this generation. |
| `frame` | `surface`, `generation`, `buffer`, `rects` | A buffer holds new pixels. |
| `cursor` | `surface`, `shape` | Pointer shape over the surface: `default`, `pointer`, `text`, `crosshair`, `move`, `grab`, `grabbing`, `not-allowed`, `wait`, `progress`, `ew-resize`, `ns-resize`, `nesw-resize`, `nwse-resize` or `none`. |
| `wantFocus` | `surface` | Ask for the keyboard. Granted only while the surface is visible and the panel already has the keyboard (the user opened it with the keyboard or clicked inside it). Never opens the panel or takes focus from another app. |

A `frame` also counts as first content for the [placeholder](#placeholders) rule.

### Buffers

When a surface first becomes visible, and whenever its size or scale changes, QNotch sends:

```json
{"type":"buffers","surface":"screen","generation":1,"width":1424,"height":644,"stride":5696,"scale":2,"format":"bgra8-premultiplied-srgb","names":["Local\\QNotch.Ext.7f3a...-0","Local\\QNotch.Ext.7f3a...-1"]}
```

- `width` and `height` are device pixels; `scale` is device pixels per QNotch layout unit (DIP on Windows, point on the Mac). The provider draws at this size. QNotch chooses it from the slot (a tab's body, a card's size) and never stretches what it gets.
- `stride` is the byte length of one row (a multiple of 64). Each buffer is `stride * height` bytes.
- Two or three buffers per generation. Their names are opened as described in [Platform transport](#platform-transport).
- The provider answers `attached` with the same `generation`. Until then QNotch shows the placeholder; a provider that does not attach within 5 seconds is shown as unavailable.
- A new `generation` replaces the previous one: the provider stops writing to the old buffers after it sees the new `buffers` message, and frames for an older generation are consumed and ignored. QNotch frees old buffers once the provider attached the new ones or 5 seconds have passed.

### Frames

QNotch keeps its own displayed image and copies changed regions into it, so a provider may redraw only what changed. How and on which thread regions are copied is up to each platform.

1. The provider writes pixels into a buffer it holds, then sends `{"type":"frame","surface":"screen","generation":1,"buffer":0,"rects":[[0,0,1424,644]]}`. `rects` lists changed regions as `[x, y, width, height]` in device pixels; at most 64, and an empty array means the whole buffer.
2. From then until QNotch sends `{"type":"consumed","surface":"screen","generation":1,"buffer":0}`, the buffer belongs to QNotch and the provider must not write to it.
3. QNotch copies the listed regions into the displayed image and consumes the buffer. Frames that arrive before QNotch next draws are all copied but drawn once, so skipped frames never leave stale pixels.

Every buffer starts as held by the provider. With two buffers the provider can draw one while QNotch reads the other; when both are with QNotch, the provider waits for `consumed`, which keeps it from drawing faster than QNotch can show.

QNotch draws at most at the display's refresh rate. Frames that arrive while the surface is hidden are consumed and not drawn. The displayed image is kept while hidden, so the surface reappears with its last picture until new frames arrive.

### Input

Input reaches a pixel surface in a tab or on a Home card while it is visible and input is enabled (see [Edit mode](#edit-mode)). Coordinates are device pixels in the surface's buffer space, with the origin at the top left.

```json
{"type":"pointer","surface":"screen","event":"down","x":512,"y":200,"button":"left","buttons":1,"modifiers":["ctrl"],"pointerType":"mouse"}
{"type":"pointer","surface":"screen","event":"wheel","x":512,"y":200,"deltaX":0,"deltaY":-120,"deltaMode":"pixel","modifiers":[]}
{"type":"key","surface":"screen","event":"down","code":"KeyA","key":"a","repeat":false,"modifiers":["shift"],"native":{"scanCode":30,"extended":false}}
{"type":"text","surface":"screen","text":"A","composed":false}
```

- `pointer.event`: `move`, `down`, `up`, `wheel`, `enter`, `leave`. `button`: `left`, `right`, `middle`, `back`, `forward`. `buttons` is the bit mask of pressed buttons (1 left, 2 right, 4 middle, 8 back, 16 forward). `pointerType`: `mouse`, `pen` or `touch`. Moves are coalesced to one per drawn frame. While a button is held the surface keeps receiving pointer events outside its bounds until release.
- `wheel` carries `deltaX` and `deltaY` with `deltaMode` `pixel` or `line`, with the W3C `WheelEvent` sign: positive `deltaY` scrolls toward the end of the content, positive `deltaX` toward the right. Each platform converts its native wheel sign and honors the user's natural-scrolling setting before sending.
- `key.code` uses the W3C UI Events `KeyboardEvent.code` names (`KeyA`, `Enter`, `ArrowLeft`, `MetaLeft`), so providers map keys the same way on both platforms. `key.key` is the layout-dependent key value. `native` is optional and platform-specific: Windows sends `scanCode` and `extended`; the Mac sends `keyCode`.
- `modifiers` is a subset of `shift`, `ctrl`, `alt`, `meta` (Windows key, Command), `capsLock`.

Keys and text:

- A keystroke that types something sends both `key` and `text`, so a provider must use one of them per keystroke or it types twice.
- While an IME composition is active, keystrokes go to the IME and no `key` is sent for them. The committed result arrives as one `text` with `composed: true`. Every other `text` has `composed: false` and follows the `key` that produced it.
- A provider that emulates a keyboard (a remote desktop) uses `key`, ignores `text` with `composed: false` and types `text` with `composed: true`. A provider that wants typed text uses `text` and uses `key` only for keys that type nothing (arrows, Enter, Backspace). Either way CJK input types once.

### Keyboard focus

A surface gets the keyboard when the user clicks it while the panel has the keyboard, or after `wantFocus` under the same condition. While it has focus:

- Every key goes to the provider, including Escape and Tab, except the shell's own shortcuts (the panel toggle and the game mode shortcut). Use the panel toggle to close the panel. Module shortcuts are released while it has focus and restored after, as Terminal does on Windows.
- Focus ends (`blur`) when the panel closes, the user clicks elsewhere in the panel, the tab changes, the surface is hidden or edit mode starts. Keys held at that moment get `up` events, and an active composition is cancelled.

### Edit mode

Cards take input like tabs do, with one exception: while Home is in edit mode, the shell owns the pointer so cards can be dragged, resized and hidden.

- When edit mode starts, QNotch ends the interaction cleanly before handing the card to the shell: held buttons get `up` and the pointer gets `leave`, a focused surface gets `blur` (held keys get `up`), and then every card surface gets `{"type":"input","surface":"...","enabled":false}`.
- While input is off, no `pointer`, `key` or `text` messages are sent for that surface, `wantFocus` is ignored, and `cursor` has no effect (the shell's drag cursor shows). Frames are still applied, so the card keeps updating while it is dragged.
- When edit mode ends, QNotch sends `{"type":"input","surface":"...","enabled":true}`. Input resumes with the next real pointer event; focus is not restored by itself, the user clicks the card again.
- A card resized in edit mode gets new `buffers` when its size changes, like any other resize.
- Every surface starts with input enabled. A surface created or shown while edit mode is on gets `input` with `enabled: false` right after `visible`.
- Tabs are not affected: the tab strip's reorder mode moves tab buttons, not tab content.

Accessibility: QNotch exposes a pixel surface as one focusable element named after its title, with the provider's `status` message as its description. Providers that need richer accessibility should offer a `view` surface alongside.

### Platform transport

Windows:

- Buffers are named file mappings, `Local\QNotch.Ext.<32 hex digits>-<index>`, with a random part per generation and a security descriptor granting access to the current user only. The provider opens them with `OpenFileMapping(FILE_MAP_WRITE, ...)` and `MapViewOfFile`.
- Regions are copied off the UI thread; the UI thread only presents and invalidates. A full frame at the example tab size is about 3.6 MB, and copying it on the thread that owns the pill would show up in input latency.

Mac:

- Buffers are POSIX shared memory objects, `/qnx.<24 hex digits>.<index>` (within the 31-character name limit), mode 0600. QNotch unlinks each name once the provider sent `attached`, or after the attach timeout, so no names outlive the exchange. The provider opens them with `shm_open(name, O_RDWR)` and `mmap`.
- The displayed image is a layer-backed view. A later revision may offer IOSurface buffers to skip the copy, as another [capability](#capabilities).

### Example session

A provider with one pixel tab, from start to the panel closing:

```text
QNotch  {"type":"hello","protocol":[1],"capabilities":["surface"],"platform":"windows","version":"1.9.0","locale":"en-US","theme":{"appearance":"dark","accent":"#4C8DFF","reducedMotion":false},"surfaces":[{"id":"screen","kind":"surface","slot":"tab"}]}
ext     {"type":"ready","protocol":1,"capabilities":["surface"]}
ext     {"type":"status","surface":"screen","state":"connecting","message":"Connecting to work-pc..."}
QNotch  {"type":"visible","surface":"screen"}
QNotch  {"type":"buffers","surface":"screen","generation":1,"width":1424,"height":644,"stride":5696,"scale":2,"format":"bgra8-premultiplied-srgb","names":["Local\\QNotch.Ext.9c...-0","Local\\QNotch.Ext.9c...-1"]}
ext     {"type":"attached","surface":"screen","generation":1}
ext     {"type":"status","surface":"screen","state":"ok"}
ext     {"type":"frame","surface":"screen","generation":1,"buffer":0,"rects":[]}
QNotch  {"type":"consumed","surface":"screen","generation":1,"buffer":0}
QNotch  {"type":"pointer","surface":"screen","event":"down","x":300,"y":120,"button":"left","buttons":1,"modifiers":[],"pointerType":"mouse"}
QNotch  {"type":"focus","surface":"screen"}
ext     {"type":"frame","surface":"screen","generation":1,"buffer":1,"rects":[[280,100,60,40]]}
QNotch  {"type":"consumed","surface":"screen","generation":1,"buffer":1}
QNotch  {"type":"blur","surface":"screen"}
QNotch  {"type":"hidden","surface":"screen"}
```

## Settings, Extensions

One page lists every extension folder found:

- Title, glyph, description and the surfaces it adds.
- The on switch, the resolved command line (or "Shows view.json; runs nothing."), and "Restart QNotch to apply your changes." when it changed.
- State: off, starting, running (with CPU use and memory), stopped (exit code, Restart button), file view (with the last `view.json` error, if any), unavailable on this platform, or invalid (the manifest error). Segment errors, which never show in the segment itself, appear here.
- Open folder and Open log.

The visibility controls in Settings, Features list extension tabs, cards and segments like any module's, so the user can hide one without turning the extension off.

## Example session

The `ci-status` provider from the [manifest example](#manifest), started at boot. Its pill segment appears only when a build fails:

```text
QNotch  {"type":"hello","protocol":[1],"capabilities":[],"platform":"windows","version":"1.9.0","locale":"en-US","theme":{"appearance":"dark","accent":"#4C8DFF","reducedMotion":false},"surfaces":[{"id":"status","kind":"view","slot":"tab"},{"id":"badge","kind":"view","slot":"pill"}]}
ext     {"type":"ready","protocol":1,"capabilities":[]}
QNotch  {"type":"visible","surface":"badge"}
ext     {"type":"view","surface":"badge","root":{"type":"stack","direction":"horizontal","children":[{"type":"icon","name":"error","level":"error"},{"type":"text","value":"Build failed"}]}}
QNotch  {"type":"visible","surface":"status"}
ext     {"type":"view","surface":"status","root":{"type":"stack","children":[{"type":"value","id":"build","label":"Build","value":"failed","level":"error","icon":"build"},{"type":"button","id":"retry","label":"Retry"}]}}
QNotch  {"type":"action","surface":"status","id":"retry"}
ext     {"type":"view","surface":"status","root":{"type":"stack","children":[{"type":"value","id":"build","label":"Build","value":"running","level":"info","icon":"build"},{"type":"progress","id":"run","label":"Build","value":null}]}}
ext     {"type":"view","surface":"badge","root":{"type":"stack","direction":"horizontal","children":[]}}
QNotch  {"type":"hidden","surface":"status"}
```

## Conformance

Fixtures are part of the contract, not an extra:

- `tests/fixtures/extensions/manifests/` holds valid and invalid manifests, each invalid one with the error it must produce. `scripts/check-extensions.mjs` validates a manifest or an extension folder (including `view.json`) against this document; the repository tests run it over the fixtures, and authors can run `node scripts/check-extensions.mjs <folder>` on their own extension.
- `tests/fixtures/extensions/sessions/` holds recorded sessions in the direction-prefixed form of the example sessions. Both hosts replay them in their tests.
- `tests/fixtures/extensions/views/` holds file-view extensions covering every element, slot and limit. Both platforms render them with `--snapshot --data-dir` (see [Parity](#parity)).
- One sample provider, written in Node (the repository already requires Node 24 for its tooling), lives under `tests/fixtures/extensions/sample/`. It runs unchanged on both platforms, exercises every message in protocol 1 and doubles as the hosts' conformance test.
