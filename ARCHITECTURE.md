# QNotch architecture

## Repository and shared principles

One repository hosts the Windows app, the website, and a native Swift/AppKit macOS development milestone. Windows remains in `src/QNotch/`; `src/QNotch.Mac/` contains the Mac shell and countdown module. The [Mac guide](docs/macos/README.md) defines its independent module and lifecycle contracts. [The platform guides](docs/README.md) describe what exists and how to contribute.

The common product contract is in [spec/README.md](spec/README.md): a small shell, independently enabled modules, explicit unavailable states, local data, bounded memory, and work driven by events and visibility. Share behavior and protocol fixtures where useful; UI controls, providers, credentials, launch behavior, and packaging belong to their platform. Do not promise matching features until both implementations support them.

Release compatibility is a repository-level contract. Read [docs/releases.md](docs/releases.md) before changing workflows, tags, assets, or update feeds. CI retains the required check named `build`, which aggregates all validation jobs and fails when any fails, is cancelled, or is unexpectedly skipped.

## Windows implementation contract

Everything below describes the existing C#/WPF Windows implementation. Existing section anchors remain valid for feature agents and external links. These Windows-specific rules do not prescribe a Mac framework, renderer, OS APIs, or memory-management techniques.

QNotch is a **shell** plus sixteen **extensions**. The shell (window, pill, panel, tabs, Home grid, Settings, tray, hotkeys, Game mode, Edit mode) knows no extension by name except the single file `Modules/ModuleList.cs`. An extension (Media, Clipboard, Ai, Agents, Notes, Github, FileTray, Stats, Notifications, Capture, Scheduled, Volume, Pomodoro, ColorPicker, Weather, Search) lives entirely in `Modules/<Name>/`: its state, providers, views, P/Invoke and settings. It plugs in through five registries (cards, tabs, settings sections, segments, search sources) and a small `IShell`. Extensions are compiled in, not loaded at runtime (no DLL plugins: cold start, no WPF unload, no isolation). Each one has an on/off switch in Settings, Features; an extension that is off is never constructed. Game mode and Edit mode are shell features, not extensions: the shell owns the mode enum, click-through, the pill and panel swap and the card grid.

C# on .NET 10, WPF, `net10.0-windows10.0.22621.0`, x64. Only NuGet dependency: CommunityToolkit.Mvvm. No System.Windows.Forms.
Build: `dotnet build -c Release` from the repo root. After publishing, launch the interactive app with `explorer.exe dist\QNotch.exe`; see [Windows development](docs/windows/development.md) for isolated noninteractive snapshots and tests.
The two publish profiles use separate intermediate and build output directories for their ReadyToRun, runtime configuration and bundle files; switching runtime variants must not reuse those artifacts. The release workflow validates each executable's embedded runtime configuration without launching it before uploading the downloads.
Data folder `%APPDATA%\QNotch`, logs in `%APPDATA%\QNotch\logs` (`qnotch.log`, `crash.log`).

Parallel test runs: set `QNOTCH_INSTANCE` (suffix of the single-instance mutex name) and `QNOTCH_DATA_DIR` (full path that replaces `%APPDATA%\QNotch`) to unique values for every run you start, and only stop processes you started (by PID). `QNotch.exe --restart` waits up to 10 s for the running instance to release the mutex (used by Settings, Features, Restart now).

Command line verbs: `Program.Main` looks the first argument up in `ModuleList.Verbs` and, on a match, runs that function and exits before any WPF type loads (`QNotch.exe notify ...` and `QNotch.exe agent [codex]`, the Claude Code and Codex hook, talk to the running instance over a pipe). A verb lives in its module's folder, must not touch WPF or shell types, and returns the exit code. The shell's one verb, `QNotch.exe debug` (the debug channel client, `Shell/Diagnostics/DebugCli.cs`), is checked right after them in `Program.Main`. Everything else starts the app.

## See your UI without driving the desktop

`QNotch.exe --snapshot <dir>` implements [the shared diagnostics contract](spec/diagnostics.md) (`Shell/Snapshot.cs`, `Shell/Diagnostics/`): it renders every view at 2x into `<dir>`, each PNG with an outline `.txt` twin (the visible controls with role, name, `#AutomationId`, value and state, plus their text, for checking content without reading pixels), then exits. Views: `pill.png` (idle, with the glance strip), `pill-peek.png` (a demo `Peek`), `pill-running`, `pill-capture`, `pill-waiting` and `pill-agent` (a running timer, the mic and camera in use, an agent that needs you, agents working), `pill-game.png` (the game bar) plus `gamebar-corner.png`, `tab-<id>.png` for every tab, `tab-home-edit.png`, `card-<id>.png` for every registered Home card on its own, `settings-<id>.png` for every settings section (a page taller than the window also gets `settings-<id>-end.png`, scrolled to the bottom), and `onboarding-<step>.png` for every welcome tour step (`welcome`, `open`, `features`, `connect`, `finish`, with demo rows: a connected GitHub account, a chosen place) plus `onboarding-features-ondemand.png`. Names come from the registries, so a new tab, card or section gets its snapshot without changing the tool. `--only "tab-*,settings-general"` renders a subset, `--appearance light|dark` (or the legacy positional `light`) forces the theme; the default follows the system. `snapshot.txt` lists `<view>: ok` or `FAILED: <view>: <reason>` per view and ends in `done` only when every view passed (exit code 0, else 1); hotkey parse details go to `snapshot.log`. It runs next to a normal instance (no single-instance lock, window off-screen, nothing is saved, every module is loaded whatever `DisabledModules` says) and, without `--data-dir` or `QNOTCH_DATA_DIR`, in a fresh temporary data folder that `Program.Main` deletes on exit. When `ctx.Settings.ReadOnly` is true a module registers everything and seeds demo data instead of starting its providers (Media shows "Midnight City", Clipboard shows sample entries): no network, no Credential Manager, no files outside the data folder written, nothing personal shown. A module whose segments change the collapsed pill registers `ctx.Demos` (`DemoState`): an `idle` state that hides them and the named state that shows them, each returning its undo, so the snapshot drives the real segments. Use it after every UI change, look at the PNGs and run `node scripts/check-snapshots.mjs <dir>`.

`QNotch.exe --smoke-test <dir>` writes the same views, then brings the shell on screen and runs the contract's smoke checks through the shell's own methods (`Shell/Diagnostics/SmokeTest.cs`, report `smoke.txt`, details `smoke.log`). A module adds its own checks by implementing `ISmokeChecks` (`Modules/SmokeChecks.cs`) in its folder, so the shell names no module: Notifications checks `notify-cli` and `notify-transport`, Agents `agents-hook`. `QNotch.exe --measure <dir>` boots like a normal start with demo data and writes `performance.json` (startup, idle CPU from exact cycle counts, working set) against the [hard limits](#performance-rules-hard), exit 1 when one fails. Both share the snapshot's read-only boot; see [Windows development](docs/windows/development.md#smoke-test).

Accessibility names: `IconButton`, `IconToggle` and `TabButton` take their UI Automation name from `ToolTip`, so every glyph button needs a string `ToolTip`. `UiKit.Row` names its control, and the unnamed slider, box or combo box of a small group, after the row's label; any other input needs `AutomationProperties.Name` (the smoke test's `accessible-names` check fails on an unnamed control). Tabs have the AutomationId `tab-<id>`.

To drive the real app instead, start a test instance with `--debug-control` (its own `--data-dir` and `QNOTCH_INSTANCE`) and use `QNotch.exe debug <command>`: state, tabs, presses through UI Automation patterns, typing, keys, outlines and snapshots of the live windows ([spec/diagnostics.md](spec/diagnostics.md#debug-channel), [Debug channel](docs/windows/development.md#debug-channel)). The channel is a current-user named pipe that exists only in that mode: a normal start creates no pipe and no thread for it.

## Folder layout (`src/QNotch`)

| Folder | Owner | Content |
| --- | --- | --- |
| `Core/` | shell | EventBus, SettingsStore, GeneralSettings, FirstRun (whether the welcome tour shows), Log, Motion, MemoryTrim, Autostart, Paths, UiCulture, CaptureWatch (which apps use the mic or camera, for any module). Names no module. |
| `Interop/` | shell | `Native` P/Invoke (LibraryImport) used by the shell |
| `Shell/` | shell | NotchWindow, ShellController (IShell, ShellMode), NotchNudge, ShellViewModel, HomeView, CardHost, CardLayout, SegmentHost, `EditMode.cs`, `GameMode/`, `Settings/` (General, Features, Hotkeys, Sounds, Appearance), `Onboarding/` (the welcome tour), TrayIcon, HotkeyService, Shortcuts, Sounds, ForegroundWatcher, Monitors, SettingsWindow, Snapshot |
| `Theme/` | shell | Dark/Light dictionaries, Styles.xaml, Glyphs, ThemeManager, UiKit, Placeholder |
| `Modules/` | shell | `Contracts.cs` (interfaces, descriptors, registries, ModuleContext), `ModuleList.cs` (the only file that names modules) |
| `Modules/<Name>/` | that module's agent | everything for one feature, including its state class |

Modules: Stats, Media, Clipboard, Ai, Agents, Notes (a `Note` namespace would hide the Notifications `Note` type), Github, FileTray, Notifications, Capture (the mic and camera indicator), Scheduled, Volume, Pomodoro (the timer; a `Timer` namespace would hide `System.Threading.Timer`), ColorPicker, Weather (forecast from yr.no; its symbol PNGs are the one `Resource` glob in the csproj), Search. Game mode and Edit mode are shell features (`Shell/GameMode/`, `Shell/EditMode.cs`).

## Rules for feature agents

You own ONLY `Modules/<YourName>/`. Do not edit anything else. The only sanctioned tiny exception: a `PackageReference` line in `QNotch.csproj` if a feature truly cannot be done without it (say so in your report). Prefer raw P/Invoke and WinRT (the TFM already projects Windows.* APIs).

Need a change in a shared file (a new IShell member, a new theme key, a new Native import)? Do not edit it: put the workaround in your folder and list the request in your report. P/Invoke you need goes in your own class (for example `Modules/Clipboard/ClipboardNative.cs`), never in `Interop/Native.cs`. New files need no csproj edit (globbing). Your module is listed once in `ModuleList.cs` (the shell owner adds the line). Styles or templates you need go in a ResourceDictionary inside your folder, merged into your own view's `Resources`.

Namespace gotchas: inside `namespace QNotch.Modules.Clipboard` the name `Clipboard` resolves to the namespace: write `System.Windows.Clipboard`. `ThemeChoice` is the theme enum (WPF has its own `ThemeMode`). WPF implicit usings exclude `System.IO`/`System.Threading`; the csproj adds them. `Native.GetCursorPos` takes a `POINT`.

## Module contract

```csharp
public sealed class MyModule : INotchModule, ICadenceAware   // ICadenceAware optional
{
    public void Initialize(ModuleContext ctx) { ... }       // UI thread, once, window handle exists
    public void SetCadence(Cadence c) { ... }               // Fast: panel open. Slow: collapsed or game bar.
}
```

- `ModuleList.All` is the list of `ModuleInfo(Id, Title, Description, Create, Early, Shared, Glyph, Setup, Tip)`. `ModuleInfo.Id` is the single module id (and the settings file name if you store settings). `Glyph` is its icon on the welcome tour's feature tile. `ModuleList.TourGroups` puts every id in one Features step group. A module the user turned off (Settings, Features; `GeneralSettings.DisabledModules`, applied on restart) is never created: no timers, hooks, hotkeys, cards, tabs, sections or segments. `Early: true` means the module registers pill or glance segments, so it initializes before the first frame; all others initialize right after it.
- An exception in `Initialize` or `SetCadence` is caught and logged; the app continues. Still, register in `Initialize` before doing risky work.
- Modules never read shell mode to decide refresh rates. React to `SetCadence` only.
- `ModuleContext`: `Bus` (EventBus), `Settings` (SettingsStore), `Hotkeys`, `Shell` (IShell), `Dispatcher`, `Cards`, `Tabs`, `SettingsSections`, `Segments`, `Search`, `Shortcuts`, `Sounds`.
- Module state lives in the module: create your own observable state object in `Initialize` (or a field initializer) and pass it to your services and views. The shell never sees it.

### Registries

`ModuleContext.QuickActions` also accepts a `QuickActionDescriptor` for a module-owned panel header control and optional tray-menu item. The shell hosts the factories without naming the module. Like other registrations, a disabled module contributes nothing. Keep controls accessible and update them from set-if-changed state, without idle polling.

```csharp
ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", DefaultOrder: 30, () => new MyCardBody(), DefaultVisible: true));
ctx.Tabs.Register(new TabDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, Order: 20, () => new MyTab()));
ctx.SettingsSections.Register(new SettingsSectionDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 30, () => MySettings.Create()));
```

```csharp
ctx.Segments.Register(new SegmentDescriptor("media.pill", SegmentSlot.PillLeft, Order: 10, () => MediaSegments.Pill(_m)));
ctx.Segments.Register(new SegmentDescriptor("stats.game.cpu", SegmentSlot.GameBar, 20, () => StatsSegments.GameCpu(_st), Title: "CPU"));
```

```csharp
ctx.Search.Register(new SearchSource("files", "File tray", Glyphs.Folder, Order: 20, q => state.Items
    .Where(i => i.Name.Contains(q, StringComparison.OrdinalIgnoreCase))
    .Select(i => new SearchHit(i.Name, i.Path, () => { svc.Open(i); shell.ClosePanel(); }))));
```

- Search sources are what the Search tab (the Search module, Ctrl+Alt+F by default) looks through. `Find` runs on the UI thread on every keystroke with the trimmed, never empty query: filter what is already in memory, case-insensitive, no I/O. The Search module shows the first 5 hits per source, in source Order, with the source Glyph and Title next to each. `SearchHit.Run` does the whole action (copy and `ClosePanel`, or `SelectTab`). `SearchHit.Snippet(text, query)` gives a one-line title around the match. With the Search module off nobody reads the registry. Orders in use: clipboard 10, files 20, note 30, notifications 40, scheduled 50, ai-apps 60, tabs 80, settings 90.
- Segments are small views the shell hosts outside the panel: `PillLeft` and `PillRight` (the pill: left cluster by Order, then right cluster), `Glance` (the strip under the collapsed pill, shown while any glance element is Visible), `GameBar` (the game bar line). Ids are unique across slots: `<module>.<slot>[.<name>]`; game bar ids are persisted keys (Settings, Game mode toggles them; Title and Hint label the toggle). Factories run once, on the UI thread, on first use (game bar: the first time the bar shows). The factory sets its own DataContext or binds with `Source` (`UiKit.Bind`, `UiKit.BindVisible`), and the element owns its Visibility for data availability ("no battery" collapses the battery). The shell owns Margin (never set your own outer Margin; glance segments get a gap between the visible ones) and, in the game bar, the per-segment user toggle. Font size in the game bar is inherited from the bar. Build segments in code to keep cold start down. Orders in use: pill left 10 (media), pill right 3 (capture), 5 (notifications), 7 (timer), 9 (weather) and 10 (stats), glance 10 (media) and 20 (notifications), game bar media 10, capture 12, notifications 15, cpu 20, gpu 30, ram 40, net 50, battery 60, timer 65, weather 68, clock 70.
- Register inside `Initialize` only (the tab strip is built once, after all modules initialized). Cards, tabs and settings sections: registering an existing id replaces it. Segments are read once (pill and glance at startup, game bar on the first entry into Game mode), so register them only in `Initialize` of an Early module (pill, glance) or any module (game bar). Factories are called once, on the UI thread. A throwing factory shows an error placeholder (a throwing segment is logged and skipped).
- Tab and card factories run at startup idle time (the shell pre-builds and pre-lays-out everything so the first open never stutters): keep them cheap, build heavy content when data arrives.
- Cards: supply only the body; `CardHost` draws the title, hover state and the order badge. Grid: 3 columns of `HomeView.Unit` (218) with `HomeView.Gap` (10) between them, row height `HomeView.RowHeight` (148). Every card supports `CardSize.Small` (one column). A descriptor can offer `CardSize.Medium` (two columns) through `DefaultSize` or `Sizes`; Home edit mode offers only its `SupportedSizes`, and `general.json` saves selections in `CardSizes` (also included in setup codes). Missing or unsupported selections use the descriptor default, preserving existing layouts. Bodies are reused and must adapt to their arranged width, including empty and unavailable states. A card spanning n columns is `n * 218 + (n - 1) * 10` wide; the body area is that minus 30 horizontally and minus about 50 vertically (card padding, border and title). Default orders in use: stats 10, weather 15, media 20, volume 25, timer 26, colorpicker 27, clipboard 30, ai-usage 40, note 45, github 50, notifications 60, ai-apps 70, files 80, scheduled 90. Tab orders: home 0, search 5, media 10, clipboard 20, ai 30, files 40, notifications 50, scheduled 60. Settings orders: general 0, features 5, hotkeys 7, sounds 8, appearance 10, gamemode 20, clipboard 30, ai 40, github 50, weather 55, notifications 60.
- Tab body area is 712 x 322 DIPs. Give tabs their own scrolling (a plain `ScrollViewer` gets the overlay style automatically) and a 19 DIP side inset so content lines up with the header and the Home grid. The shell wraps your tab in its own container (fade/slide on switch): do not rely on your view's `Parent` type. Inactive tabs are `Hidden` (laid out, not rendered): do not run animations or timers because a view is loaded; use `ctx.Shell.ActiveTab` / `TabChanged` plus cadence.
- Settings sections: `UiKit.Page(title)` plus `UiKit.Row(label, hint, control)` gives the standard layout; the window provides the scrolling.
- `TabDescriptor.IsEmpty` (optional `Func<bool>`): return true while the tab has nothing to show. When the panel opens and the last tab is empty, the shell opens Home instead (except during a file drag, which selects the Files tab as the drop target).
- Every view needs explicit empty and "unavailable" states (use `Placeholder.Create(glyph, title, message)`). Never show 0% or an empty list when data is unavailable.

### Welcome tour rows and tips

```csharp
new("github", "GitHub", "...", () => new GithubModule(), Glyph: Glyphs.Github, Setup: c => GithubSetup.Create(c), Tip: c => "...");
```

- `ModuleInfo.Setup` (optional): a static factory for the welcome tour's Connect step, returning a `SetupRow(Title, Glyph, Status, Action, Detail)` or null when there is nothing to set up (Agents with no agent installed). It runs before the module exists (first run), so it uses only static helpers, `SetupContext.Settings` and the credential store: no providers, bus, shell or timers, and the tour itself makes no requests. The module keeps `Status` (text and brush) current; `Detail` sits under the row and is collapsed while empty; work a row starts (GitHub polling) stops when its elements unload or hide. The running module picks up what a row saved when it starts; when the tour is opened from Settings while the module runs, the row raises a static event in its folder (`GithubSetup.TokenSaved`, `WeatherSetup.PlaceChosen`) that the module handles. `SetupContext.Demo` (snapshot) shows demo values and writes nothing. Wrap the factory in a lambda so a normal start does not load the row's type.
- `ModuleInfo.Tip` (optional): one line for the tour's last step with real gestures (`SetupContext.Shortcuts.GestureOf(id, default)` reads a gesture before its module declared it), shown only while the module is on.

### Hotkeys and window messages

```csharp
// A hotkey the user can change: declare it, the shell does the rest (saved gesture, registration, a row in Settings, Hotkeys).
_key = ctx.Shortcuts.Add("search", "Open search", "Opens the Search tab with the cursor in the box.", "Ctrl+Alt+F", Summon, order: 20);
ctx.Shortcuts.Enable(_key, false);                               // while you have no use for it: the key is left to other apps
ctx.Hotkeys.Register(ModifierKeys.None, Key.Escape, Cancel);     // raw, only for a key held for a moment; Unregister when done
HwndSourceHook hook = (nint hwnd, int msg, nint w, nint l, ref bool handled) => { ... return 0; };
ctx.Shell.AddHwndHook(hook);                                     // e.g. WM_CLIPBOARDUPDATE, WM_DISPLAYCHANGE
```
Every lasting global hotkey goes through `ctx.Shortcuts` (`Shell/Shortcuts.cs`), never `ctx.Hotkeys`: call `Add(id, title, hint, defaultGesture, action, order, enabled)` once per id in `Initialize` (gesture in KeyGestureConverter syntax). The returned `Shortcut` has `Gesture` (empty when the user turned it off), `Enabled` and `Taken` (another app owns the key); `Shortcuts.Changed` fires when any of them change, so show the gesture from there and never hardcode it in UI text. Changed gestures are saved in `hotkeys.json` (id to gesture); the shell's own two are `toggle` and `gamemode`. Orders in use: toggle 0, gamemode 10, search 20, ai.slot1 to ai.slot6 30 to 35.

### Sounds

```csharp
_done = ctx.Sounds.Add("timer.done", "Timer is up", "A timer reached zero.", "SystemExclamation", order: 30);  // in Initialize
ctx.Sounds.Play(_done);                                                                                         // UI thread, asynchronous
```
Every sound goes through `ctx.Sounds` (`Shell/Sounds.cs`), never `PlaySound` or `SystemSounds` directly. A sound plays its Windows sound scheme alias (so one the user turned off there stays off) until the user picks an audio file in Settings, Sounds; a missing or broken file falls back to the alias. Chosen files are saved in `sounds.json` (id to path) and are never shared in setup codes. Whether a sound plays at all (game mode, calls, a toggle) is the module's call. Orders in use: notifications.toast 10, agents.needsyou 20, agents.done 21, timer.done 30.

`ctx.Shell.Hwnd` is the window handle (for `AddClipboardFormatListener`). Hotkey actions and hooks run on the UI thread. Clipboard reads can block while the source app renders delayed formats: keep the UI-thread read small (formats check, text, a size-capped bitmap) or read on a dedicated STA thread and post the result.

### IShell (what you can ask of the shell)

All members are UI thread only.

- `Hwnd`, `AddHwndHook`.
- `ActiveTab` / `TabChanged`, `SelectTab(id)`, `ClosePanel()`, `OpenSettings(sectionId)`.
- `TryOpenPanel(tabId, lingerMs)`: opens the panel without taking the keyboard, optionally on a tab. Returns false in game mode (nothing opens). When the pointer is elsewhere, the panel closes again after `lingerMs` (at least the leave delay). For something the user must see now (Notifications uses it for errors), never for routine updates.
- `OpenPanelWithKeyboard(tabId)`: opens the panel and takes the keyboard, like the toggle hotkey (Esc or a click elsewhere closes it). Returns false in game mode. Only for an explicit summon by the user: Search uses it for its hotkey, then focuses its box.
- `Peek(glyph, text, brushKey, ms)`: widens the collapsed pill for a moment (4 s by default) to show one line in place of its segments ("api: Needs you"). A newer peek replaces the shown one; dispose the returned handle to end it early (Agents does when the session is answered). Nothing shows while the panel is open; returns null in game mode, where the caller should stay quiet too. For something the user must notice whatever app is in front, never for routine updates.
- `IsPinned` (get only).
- `HoldOpen()` returns an `IDisposable`: while any hold is alive the panel never auto-closes (pointer leave, focus loss). Wrap `DragDrop.DoDragDrop`, file dialogs, context menus and card drags in `using (ctx.Shell.HoldOpen()) { ... }`. On release the shell asks the OS where the pointer is and closes after the leave delay if it is outside.
- File drops: `FilesDropped(string[] paths)` fires for files dropped anywhere on the panel that no element handled; `FileDragEntered` fires once when a file drag enters the notch. While nobody subscribes, the notch refuses file drops. The shell opens the panel itself when files are dragged over the pill (after the hover dwell).

Everything else (mode, keyboard focus, foreground watcher, monitor, general settings, game mode, edit mode) is shell internal and stays on `ShellController`. `TextBox` and `PasswordBox` inside the panel take the keyboard automatically on mouse down; the keyboard is released when the panel closes or the user clicks elsewhere. Esc closes the panel only while the window has the keyboard.

### Shell features (not modules)

- Game mode (`Shell/GameMode/GameModeController.cs`): detects a fullscreen app (foreground hook, WM_DISPLAYCHANGE, a scoped location hook), debounces entry by 250 ms, and switches the shell to `ShellMode.GameBar` (hover, hotkey, tray and file-drag opening off, window click-through, pill and panel hidden, glance hidden). The bar is built on first entry from the registered `GameBar` segments, each wrapped in a Border whose Visibility is the user toggle (`gamemode.json`, `Segments`: id to bool, missing means on; ). The Ctrl+Alt+G hotkey and the tray menu drive `GameMode.Override` (Auto, ForceOn, ForceOff). `Start()` runs after the first frame.
- Edit mode (`Shell/EditMode.cs`): the header pencil toggles `IsEditMode` (only while the panel is open and `Motion.Enabled`; the panel never auto-closes while it is on). `CardLayout.Hosts` is the live ordered list of `CardHost`; a reorder is persisted with `CardLayout.Move(id, targetId)`, visibility with `SetVisible(id, bool)`. The tab strip reorders in the same mode (`Shell/TabReorder.cs`): tabs jiggle, drag sideways, and `ShellController.MoveTab(id, targetId)` saves `GeneralSettings.TabOrder` (unlisted tabs follow by `TabDescriptor.Order`; ids of tabs that are gone keep their slot); a press without a drag still opens the tab.
- Updates (`Core/Updates/`, `Shell/Settings/UpdatesSection.cs`): an app lifecycle service created by `App`, with Settings, Updates and a pill indicator registered before the shell starts. `GeneralSettings.CheckForUpdates` defaults on. The first start opens Settings, Updates with Keep enabled / Turn off; `UpdateChecksChoiceMade` remembers the answer, and the toggle also confirms it. Unconfirmed older settings adopt the default once; an explicit choice is preserved. These local preferences are excluded from setup codes. `TrayIcon` sends a Windows notification for a new release, opens Updates on click, respects games and quiet time, and persists `LastNotifiedUpdateVersion` to avoid repeat notifications across restarts. Checks stable GitHub releases 10 seconds after startup and every six hours using a one-shot timer, or on demand. Installation is an explicit button action: download the matching runtime variant, check GitHub's SHA-256 digest and the executable's x64 header/version, then launch the embedded PowerShell helper hidden. The helper signals readiness before QNotch exits, waits for its process, atomically replaces the exe with a backup, and restarts through Explorer. Failed replacement or restart restores/reopens the original where possible; a result file reports success or failure on the next start. Snapshot mode seeds an available-update example without timers or network requests. `QNotchSelfContained` assembly metadata is set after the publish profile; tagged release builds override the project's local version using `-p:Version`.
- Welcome tour (`Shell/Onboarding/`, contract in [spec/onboarding.md](spec/onboarding.md)): `FirstRun.Decide` picks at boot. Without `general.json` (a fresh install) `App` declares the shell's shortcuts (`ShellController.AddShortcuts`), then runs the tour modally before the update service and any module exist, so the feature choices become `DisabledModules` with no restart and a completed or skipped tour records `UpdateChecksChoiceMade` (no Settings, Updates prompt). Existing settings without `OnboardingDone` get it set silently; `--snapshot` never shows it. Settings, General, Show welcome tour opens it on demand with a read-only Features step. Steps: `welcome`, `open` (the toggle gesture as key caps, Change with the Settings, Hotkeys rules, Try it now detected in the window while global hotkeys are suspended), `features` (tiles in `ModuleList.TourGroups`), `connect` (the `Setup` rows of enabled features; left out when there are none) and `finish` (updates, Start with Windows, tips; Open QNotch opens the panel on Home with the keyboard). Always dark. Motion (`TourMotion`, `TourStyles.xaml`, `TourFlight`): opacity and render transforms only, every tween ends with `FillBehavior.Stop` on its final local value; directional step transitions with a parallax hero and staggered text, a sliding progress pill, per-step hero moments, and Open QNotch flies a picture of the tour into the notch in a short-lived transparent window while the real one is DWM-cloaked. The only loops (the key caps on the open step, the GitHub waiting dot) run while visible and not minimized. With `Motion.Enabled` off steps crossfade in 120 ms and nothing slides, scales, staggers or loops; `--snapshot` renders every step settled. `TourChoices` holds the result logic (checked by `tests/QNotch.OnboardingTests`); the tour's types load only when it is shown. GitHub sign-in is the OAuth device flow in `Modules/Github/GithubOAuth.cs` (`ClientId` is the public id of QNotch's OAuth App; an empty id hides every Sign in with GitHub button).

### Enable switch

Windows presentation is independent of enablement. Settings, Features lists the Home cards, tabs and notch segments actually registered by each running module. Home visibility and ordering continue to use `GeneralSettings.CardVisible` and `CardOrder`; game-bar segments retain their existing choices. `windows-presentation.json` stores tab and pill/glance visibility locally, outside setup codes. Weather retains its existing `ShowInPill` preference. Hiding a surface applies live without reconstructing the module. Hidden tabs retain `TabOrder`, cannot be navigated to, and fall back to Home if selected or last selected. Search releases its shortcut while its tab is hidden and restores the saved gesture when shown. Features stays reachable even when Home has no cards. A feature disabled at boot must be enabled and restarted before its presentation controls are available.

Settings, Features has one switch per `ModuleList.All` entry. A switch edits `GeneralSettings.DisabledModules` (general.json) and shows "Restart QNotch to apply your changes." with a "Restart now" button (`QNotch.exe --restart`). At boot `App` skips every disabled module: `Create` is never called, so it has no timers, hooks, hotkeys, cards, tabs, sections or segments and costs nothing. Ids of cards of a disabled module stay in `CardOrder`, so turning the module back on restores its slot. `--snapshot` ignores the list and loads everything.

### Add a new extension

1. Create `Modules/<Name>/` with `<Name>Module.cs` implementing `INotchModule` (and `ICadenceAware` if it refreshes data).
2. Put its state (an `ObservableObject`, set-if-changed properties), providers, views and P/Invoke in the same folder. Nothing in `Core/`, `Shell/` or `Interop/` changes.
3. In `Initialize`, register what it shows: `ctx.Cards`, `ctx.Tabs`, `ctx.SettingsSections` and, for the pill, glance strip or game bar, `ctx.Segments`. Start providers after registering, and honor `ctx.Settings.ReadOnly` (snapshot run: demo data, no providers, no network or credentials; register `ctx.Demos` for anything it adds to the collapsed pill).
4. Add one line to `ModuleList.All` (`Early: true` only if it registers pill or glance segments), and one to `ModuleList.Verbs` if it has a command line verb.
5. Build, run `QNotch.exe --snapshot <dir>` (its cards, tab and settings section appear as `card-<id>.png`, `tab-<id>.png` and `settings-<id>.png` by themselves), look at the PNGs and outlines, run `node scripts/check-snapshots.mjs <dir>`, then measure idle CPU and memory against the performance rules below.

## State and threading

- There is no shared model. Each module owns its observable state (all `[ObservableProperty]`, set-if-changed) and only touches it on the UI thread.
- Providers do all I/O and sampling on the thread pool and hand results over the bus:

```csharp
// background thread
ctx.Bus.Post(new ClipboardCaptured(text));                    // typed event, any thread, never blocks
ctx.Bus.Run(() => _media.Title = title);                      // or run an action on the UI thread
// Initialize (UI thread)
ctx.Bus.Subscribe<ClipboardCaptured>(e => _state.Add(e));
```
  Posts are coalesced into one dispatcher callback. There is no polling anywhere; use OS events, or a one-shot `System.Threading.Timer` you re-arm for cadence.
- Keep text ready to render in the state ("--" before the first sample, "n/a" when unavailable), so a segment is a few bindings and unchanged data raises no change.

## Settings

One JSON file per module, so nobody edits a shared class:

```csharp
public sealed class MediaSettings { public bool ShowArtwork { get; set; } = true; }
var s = ctx.Settings.Get<MediaSettings>("media");   // cached live instance, defaults if missing or corrupt
s.ShowArtwork = false;
ctx.Settings.Save("media", s);                       // debounced 500 ms, atomic (temp file then move)
```
Enums serialize as strings. The shell's own settings are `GeneralSettings` (`general.json`): monitor index, hover dwell 120 ms, leave delay 400 ms, pinned, hotkeys, accent, theme, reduce motion, profile, card order/visibility, tab order, last tab, start with Windows, `DisabledModules`, `OnboardingDone` (a local preference, never in setup codes). It is an ObservableObject persisted by the shell. Secrets (tokens) never go in JSON: use `Windows.Security.Credentials.PasswordVault`.

Setup codes (Settings, General, Share your setup) carry chosen fields of these files to another PC. A module opts in with `Shared` on its `ModuleInfo` in `ModuleList.cs`, naming the fields of its settings file: `Shared: new(typeof(TimerSettings), "Minutes:1..180")` (a number gets a range). Share only plain preferences: never personal data, paths, history, or anything that starts a program or opens a port. Reading a code drops unknown files and fields, checks ranges and sizes, and requires each file to still load as its type; applying writes the files and restarts. The shell's own shared fields are in `Shell/Settings/SetupCode.cs`.

## Theme

Always use `DynamicResource` for brushes so theme and accent switch live. Keys: `SurfaceBrush`, `SurfaceRaisedBrush`, `WindowBrush`, `CardBrush`, `CardHoverBrush`, `StrokeBrush`, `StrokeStrongBrush`, `ControlBrush`, `ControlHoverBrush`, `ControlPressedBrush`, `TextPrimaryBrush`, `TextSecondaryBrush`, `TextTertiaryBrush`, `AccentBrush`, `AccentHoverBrush`, `AccentSoftBrush`, `OnAccentBrush`, `ToggleKnobOnBrush`, `DangerBrush`, `SuccessBrush`, `WarningBrush`, `ScrollThumbBrush`. Fonts: `UiFont` (Segoe UI Variable), `IconFont` (Segoe Fluent Icons, fallback Segoe MDL2 Assets). Converter: `BoolToVis`. The notch window uses tabular numerals, so changing digits never shift layout.
Styles: TextBlock `Title`, `Caption`, `Muted`, `Glyph`; Button (implicit), `AccentButton`, `LinkButton` (accent text, no background), `IconButton`, `IconToggle` (ToggleButton), `TabButton`, `NavButton`, `SegmentButton` (RadioButton), `ToggleSwitch` (CheckBox); implicit TextBox, PasswordBox, CheckBox, ComboBox, ListBox, ListBoxItem (rounded rows with hover and selection), Slider, ProgressBar, ScrollViewer (overlay scrollbars shown on hover), ScrollBar, ContextMenu, MenuItem, ToolTip. Implicit styles skip subclasses: a class deriving from ScrollViewer (or any styled control) must set `Style = (Style)Application.Current.FindResource(typeof(ScrollViewer))`. Every interactive element has a hover state; keep it that way.
Glyph constants: `Theme/Glyphs.cs`. Code helpers: `UiKit.Page/Row/Toggle(value, set)/Text/Glyph/Header/Bind/BindVisible`, `Placeholder.Create`.
Spacing scale: 4, 8, 12, 16, 24. Radii: 6 chips, 8 controls, 14 cards, 26 panel. Typography: 11 captions and hints, 12 body, 13 emphasis, 14 titles, 20 settings page headers. Never use an em dash in UI text or docs.

## Performance rules (hard)

- Idle CPU at or under 0.1% while collapsed. Nothing faster than 1 s while collapsed; clock on the minute boundary; event-driven wherever Windows offers events.
- Zero repaints while collapsed and idle: no forever-running storyboards or animated effects; unchanged data must not raise property changes (properties are set-if-changed; format text in the provider, not in a per-tick converter).
- No `DropShadowEffect` or `BlurEffect` on large or animated elements. Prefer frozen brushes and images (`Freeze()`; decode thumbnails with `DecodePixelWidth`).
- Animations: check `Motion.Enabled` (user setting and OS animation setting) and skip them when false. Animate transforms and opacity, not layout, and remove the animation when done (`FillBehavior.Stop` after setting the final local value; no HoldEnd forever). An animation that must loop (edit mode jiggle) runs only while its trigger is on and is removed with `BeginAnimation(prop, null)` when it ends.
- The notch is a layered window rendered in software (`RenderOptions.ProcessRenderMode = SoftwareOnly`: same frame rate as hardware for this window, 20 MB less commit). Every animated frame re-renders the whole 760 x 430 surface, roughly 5 ms of CPU. Keep animations short (under 300 ms); a looping animation (edit mode jiggle) must set `Timeline.DesiredFrameRate` to 30 or less and stop when its trigger ends.
- Providers never block the UI thread. Anything over about 2 ms goes to the thread pool.
- The panel is `Collapsed` while closed, so nothing inside it is laid out or rendered then. Inactive tabs are `Hidden` while it is open.
- Tiered JIT is off (`TieredCompilation=false` in the csproj): at a 5 s idle cadence the background tier-up JIT cost 10x the app's own work. Do not turn it back on. Measured idle (collapsed, 40 s window, exact cycle counts): about 4.5 ms CPU per 5 s tick.
- Resident memory under 80 MB: the shell trims once after startup and after each panel close (`MemoryTrim`). Do not cache unbounded data.

## Shell behaviour summary

Window: fixed 760 x 430 DIPs layered topmost tool window (`WS_EX_LAYERED|TOOLWINDOW|TOPMOST|NOACTIVATE`), top-center of the chosen monitor's full bounds; transparent pixels are click-through (OS per-pixel hit testing). Pill 38 DIPs tall, panel 720 x 380. Re-anchors on `WM_DPICHANGED` and `WM_DISPLAYCHANGE`, reasserts topmost on every foreground change. Hover opens the panel after the dwell, closes after the leave delay unless pinned, a text box holds the keyboard, edit mode is on, or a `HoldOpen` is alive. Ctrl+Alt+N and a tray click toggle the panel and take keyboard focus (Esc or a click elsewhere closes it and focus returns to the previous app); Ctrl+Alt+G cycles the Game mode override (Auto, Force on, Force off). Tray icon: left click toggles, right click menu (Open panel, Settings, Game mode override, Exit). Sideways offset (`NotchNudge`): press on the collapsed pill or the empty part of the panel header and drag; release projects the momentum, snaps to the center or a monitor edge within 56 DIPs, and springs there (Rendering hooked only while it moves). When the pointer crosses onto another monitor mid-drag, `GeneralSettings.MonitorIndex` switches to it and the pill keeps the same grip on the new monitor. A plain click on the pill opens the panel; a double-click centers it. The spot is saved per foreground app in `GeneralSettings.NotchSpots` (process name to DIPs from center, +-10000 for an edge) and restored on foreground change; the taskbar, desktop, Start, search, QNotch itself and windows on another monitor are ignored. The window is clamped to the monitor and the rest of the offset is a shift of the surface inside it, so the open panel always fits on screen. Game mode keeps its own offsets. Open animation: 240 ms with a light spring; close 180 ms ease-out; tab switches slide the indicator and fade the new tab in; all skipped when `Motion.Enabled` is false. Cadence: Fast while Expanded, Slow otherwise.
