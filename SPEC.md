# QNotch: specification

A personal, performance-first Windows "notch" overlay modelled on BuildNotch 1.1.0 (buildnotch.app, reviewed 2026-09-30). BuildNotch ships as a Tauri app (Rust core + WebView2 UI). QNotch keeps a trimmed feature set, drops the web view, and adds a Game mode: native rendering, near-zero idle CPU, small resident memory, instant hover response.

## 1. Goals and non-goals

Goals

- Idle CPU at or under 0.1% while collapsed. No polling timers faster than 1 s while collapsed; event-driven wherever Windows offers an event.
- Resident memory under 40 MB (Rust target) or under 80 MB (C# target).
- Hover-to-open latency under 50 ms, 60 fps open/close animation, no first-open stutter (pre-render the panel).
- Cold start under 300 ms to a visible collapsed notch.
- Single portable executable plus a data folder. No installer, no licensing, no telemetry.
- Windows 11 primary, Windows 10 2004+ acceptable. x64 only.

Non-goals

- Multi-platform. Notch is Windows-only.
- Cloud sync, accounts, payments.
- Replacing Windows clipboard history (Win+V). QNotch's clipboard is a session convenience layer.
- Productivity widgets (timers, tasks, projects, notes-as-todo, quotes, app launchers, code scratchpad). Deliberately left out to keep the surface small.

## 2. Shell: the notch itself

Collapsed state (always visible)

- Centered pill at the top edge of the chosen monitor, roughly 40 px tall, width adapts to content. Topmost, click-through outside the pill, no taskbar entry, no focus steal.
- Left cluster: now-playing artwork thumbnail, track title, artist.
- Right cluster: live CPU %, GPU % if available, RAM used / total, battery % with charging glyph, clock (HH:MM).
- Glance layer: when the panel is closed, a slim strip under the pill shows the now-playing line and nothing else.

Expanded state (panel)

- Opens on hover after a short dwell (default 120 ms), or on a global hotkey. Closes on mouse leave after a grace period (default 400 ms) or Esc. Pinned mode keeps it open.
- Tab strip with icon tabs: Home, Media, Clipboard, AI, Files.
- Home is a responsive card grid. Every card has a fixed order number, shown as a badge in Edit mode.
- Edit mode: cards jiggle, lift on drag, settle on drop. Reorder is persisted. Disabled when the OS "reduce animation" setting is on.
- Appearance settings: show/hide each card. Hidden cards remember their slot when re-enabled.
- Profile image and display name in the panel header.
- Multi-monitor: choose which monitor hosts the notch. Follow DPI changes without restart.

Window plumbing (both stacks)

- Layered, per-pixel-alpha, topmost tool window (`WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE`).
- Hover detection without a low-level mouse hook: the collapsed pill window itself receives `WM_MOUSEMOVE`; use `TrackMouseEvent` for leave. No `WH_MOUSE_LL`.
- Re-assert topmost on `WM_DISPLAYCHANGE`, `WM_DPICHANGED`, and when the foreground window changes.
- Global hotkeys via `RegisterHotKey`. Defaults: toggle panel, Alt+1..6 launch AI shortcut N, toggle Game mode override.

## 3. Game mode

When a fullscreen or borderless-fullscreen application owns the foreground, the notch stops being an interactive panel and becomes a slim, passive status bar.

Detection

- Subscribe to foreground changes with `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` and to `WM_DISPLAYCHANGE`. No polling.
- On each foreground change, classify the foreground window as fullscreen when all hold: its window rect covers the entire monitor it is on (`MonitorFromWindow` + `GetWindowRect`), it is not the desktop or shell (`Progman`, `WorkerW`, taskbar classes), and it is not QNotch itself. This catches both exclusive fullscreen and borderless windowed.
- Also honor `SHQueryUserNotificationState` values `QUNS_BUSY`, `QUNS_RUNNING_D3D_FULL_SCREEN`, `QUNS_PRESENTATION_MODE`. Exclusive-fullscreen D3D games may not report a rect at all; this covers them.
- Debounce entry by 250 ms so Alt-Tab flicker does not toggle modes. Exit is immediate.
- Per-process allow / deny list in settings: force Game mode for a process, or exempt one (for example a borderless video player you still want to interact with).
- Manual override hotkey cycles Auto, Force on, Force off. Tray icon shows the current mode.

Status bar behavior

- Hover and hotkey panel opening are disabled. The window becomes fully click-through (`WS_EX_TRANSPARENT`) so no input is swallowed.
- The pill shrinks to a single-line bar, target height 22 px, low opacity (default 70%, configurable), no artwork, no animation.
- Content, left to right: track title and artist (if playing), then CPU %, GPU % if available, RAM used, network throughput, battery, clock. Each segment individually toggleable for Game mode only.
- Optional frame-time / FPS readout is out of scope for v1 (needs a presentation hook); leave a slot for it.
- Sampling rates stay at the collapsed values (stats every 5 s, clock on the minute). Media events remain subscribed. Clipboard capture continues in the background.
- Repaint only on data change. The bar must never hold a render loop while a game runs.
- Position: same top-center anchor by default, with a Game-mode-only offset setting so it can sit in a corner or be moved off the game's HUD area.
- The topmost z-order is reasserted after the foreground change. If the game is true exclusive fullscreen the bar will not be visible regardless; QNotch does not attempt to inject or overlay in that case.
- Leaving Game mode restores the previous pill size, opacity, and pinned state with a short fade.

## 4. Feature cards

### 4.1 Media (now playing)

- Source: Windows Global System Media Transport Controls (`GlobalSystemMediaTransportControlsSessionManager`). Works with Spotify, browsers, VLC, any app publishing a session.
- Shows artwork, title, artists, elapsed / total time, a progress bar, and play/pause, previous, next controls.
- Subscribe to `MediaPropertiesChanged`, `PlaybackInfoChanged`, `TimelinePropertiesChanged`. Progress bar interpolates locally between timeline events at 1 Hz while visible, 0 Hz while collapsed.
- Multiple sessions: follow the "current" session as reported by Windows; allow manual session pick in a dropdown.

### 4.2 AI apps

- Auto-detect installed AI desktop apps at startup and on demand: ChatGPT, Claude, Cursor, Codex, Antigravity are the ones BuildNotch shows. Detection order: registry uninstall keys, Start menu shortcuts, known install paths under `%LOCALAPPDATA%` and `%PROGRAMFILES%`.
- User can add custom shortcuts. Slots 1 to 6 map to Alt+1..6.

### 4.3 AI usage

- Dedicated AI tab. For each supported signed-in tool, show usage windows (for example a 5-hour window and a weekly window), percent used, percent left, and the reset timestamp when the provider supplies one.
- Data arrives per provider as it responds. Show a last-reading time. A provider that fails or is signed out is marked "unavailable", never shown as 0% used.
- Manage which providers appear. Refresh interval default 10 min, manual refresh button.
- Implementation note: this reads each tool's local credential store and calls its usage endpoint. Treat as best-effort and isolate each provider behind a trait / interface so breakage in one never affects the rest.

### 4.4 GitHub activity

- Contribution graph for the signed-in user plus totals like "333 contributions, 83 day streak".
- Source: GitHub GraphQL `contributionsCollection` with a personal access token stored in Windows Credential Manager. Refresh hourly and on demand. Cache the last response on disk so the card renders offline.

### 4.5 Personal note

- Single free-text note with a date label, word count, and a "Saved" indicator. Auto-save with a 500 ms debounce. Plain text, stored as a file.

### 4.6 Clipboard history

- Listen with `AddClipboardFormatListener` and `WM_CLIPBOARDUPDATE`. Capture text and bitmaps.
- Classify text into Text, Code, Link. Filters: All, Text, Code, Images. Code detection is heuristic (braces, semicolons, indentation, keywords) and cheap.
- Keep the 40 most recent entries in memory. Oldest drops off. No persistence by default (matches BuildNotch and avoids storing secrets). Optional persistence and pinning as a setting, default off.
- Actions: copy again, remove one entry, clear all. Ignore clipboard formats flagged as sensitive by password managers (`ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory = 0`).
- Cap stored image size at 4 MB per entry.

### 4.7 File tray

- Drop files onto the panel to add a reference to the tray. Show name and thumbnail (shell thumbnail API). Drag out to another app, or export. Removing from the tray never touches the original file. Tray persists across restarts as a list of paths; missing files show as stale.

### 4.8 System stats

- CPU %, RAM used / total, network throughput, battery % and charging state, clock. GPU % where the adapter exposes it through `D3DKMTQueryStatistics` or the performance counter `GPU Engine`.
- CPU via `GetSystemTimes` delta, RAM via `GlobalMemoryStatusEx`, network via `GetIfTable2` delta, battery via `GetSystemPowerStatus`. Sample at 1 Hz while the panel is open, at 5 s while collapsed or in Game mode. Clock updates on minute boundary only.

## 5. Settings

- General: start with Windows, monitor selection, hover dwell and leave delay, pinned mode, global hotkeys.
- Features: one switch per module (System stats, Now playing, Clipboard, AI, Note and GitHub, File tray). A module that is off is never loaded; the change applies on restart.
- Game mode: auto detection on/off, opacity, height, segment toggles, position offset, per-process allow / deny list.
- Appearance: card visibility and order, accent color, light / dark / follow system, reduce motion.
- Integrations: GitHub token, AI provider toggles, clipboard persistence.
- Data folder: `%APPDATA%\QNotch`. Human-readable JSON or TOML files with atomic write (write temp, rename). No database needed at this scale.

## 6. Architecture

Core

- One process, one UI thread, one background worker pool. All integrations (media, clipboard, stats, GitHub, AI usage) are independent providers that push typed events onto a single channel the UI drains. No provider may block the UI thread.
- State is a single in-memory model; cards render from it. Persistence is a debounced snapshot of the parts that need it.
- Every provider has an "unavailable" state that renders explicitly.
- Shell mode is a single enum (Collapsed, Expanded, GameBar) owned by the shell. Providers do not know about modes; the shell decides what to draw and at what rate.

Rendering

- Retained scene with dirty tracking. Repaint only on state change or during an animation. Zero repaints while collapsed and idle, and zero while in Game mode between data changes.
- Pre-build the panel on startup so the first open is as fast as later ones.

## 7. Stack recommendation

| Criterion | Rust | C# (.NET 10) |
| --- | --- | --- |
| Idle CPU, memory | Best. 15 to 30 MB typical. | Very good. 50 to 80 MB with ReadyToRun and trimming. WPF cannot use NativeAOT. |
| Windows API access | `windows` crate covers Win32 and WinRT (media sessions included). Verbose but complete. | First-class. WinRT projections and P/Invoke are trivial. |
| UI toolkit for a transparent, animated overlay | Slint (declarative, retained, GPU) or egui (immediate mode, code-only). Transparent layered windows on Windows need care with the renderer choice. | WPF: per-pixel-alpha layered windows, animations, drag and drop, and styles are mature and well documented. Avalonia is the alternative if you want Skia rendering. |
| Time to a polished result | Slower. Drag reorder and thumbnails are hand-built. | Faster. Most of the UI list above is built-in. |
| Long-term maintenance for a solo hobby project | Fine, small dependency surface. | Fine, and easier to pick back up after months away. |

Recommendation: Rust with the `windows` crate for all system integration and Slint for the UI if the performance targets in section 1 are the point of the project. With the productivity widgets removed the UI surface is small enough that the Rust path is no longer much slower to build. Pick C# with WPF only if you want WPF's built-in drag and drop and styling. Either way, do not use a web view.

If you go Rust, the crates that matter: `windows` (Win32 + WinRT), `slint` (UI), `tokio` (provider tasks), `reqwest` with `rustls` (GitHub and AI usage), `serde` + `serde_json` (state), `image` (artwork and thumbnails), `keyring` (token storage).

If you go C#: .NET 10, WPF, `Microsoft.Windows.SDK.Contracts` or CsWinRT for media sessions, `System.Text.Json`, `Windows.Security.Credentials.PasswordVault` for tokens. Publish with ReadyToRun, single file, trimmed.

## 8. Build order

1. Shell: layered topmost window, hover open and close, panel animation, settings file. Verify idle CPU and memory targets before adding anything else.
2. System stats and clock in the pill.
3. Game mode: foreground hook, fullscreen classification, status bar rendering, override hotkey. Verify zero repaints while a game is running.
4. Media card.
5. Clipboard history.
6. AI app detection with hotkeys.
7. Personal note, GitHub.
8. File tray, AI usage, Edit mode polish.

## 9. Out of scope for v1, worth noting from the Notchify comparison

Weather, calendar, world clock, Bluetooth device battery, audio output switching, volume and brightness, lock / sleep / screenshot actions, notification mirroring, carousel widget stacks, FPS overlay. Add only if you reach for them daily.
