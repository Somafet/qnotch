# QNotch architecture (contract for feature agents)

QNotch is a **shell** plus twelve **extensions**. The shell (window, pill, panel, tabs, Home grid, Settings, tray, hotkeys, Game mode, Edit mode) knows no extension by name except the single file `Modules/ModuleList.cs`. An extension (Media, Clipboard, Ai, NoteGithub, FileTray, Stats, Notifications, Scheduled, Volume, Pomodoro, ColorPicker, Search) lives entirely in `Modules/<Name>/`: its state, providers, views, P/Invoke and settings. It plugs in through five registries (cards, tabs, settings sections, segments, search sources) and a small `IShell`. Extensions are compiled in, not loaded at runtime (no DLL plugins: cold start, no WPF unload, no isolation). Each one has an on/off switch in Settings, Features; an extension that is off is never constructed. Game mode and Edit mode are shell features, not extensions: the shell owns the mode enum, click-through, the pill and panel swap and the card grid.

C# on .NET 10, WPF, `net10.0-windows10.0.22621.0`, x64. Only NuGet dependency: CommunityToolkit.Mvvm. No System.Windows.Forms.
Build: `dotnet build -c Release` from the repo root. Run: `src/QNotch/bin/Release/net10.0-windows10.0.22621.0/win-x64/QNotch.exe`.
Data folder `%APPDATA%\QNotch`, logs in `%APPDATA%\QNotch\logs` (`qnotch.log`, `crash.log`).

Parallel test runs: set `QNOTCH_INSTANCE` (suffix of the single-instance mutex name) and `QNOTCH_DATA_DIR` (full path that replaces `%APPDATA%\QNotch`) to unique values for every run you start, and only stop processes you started (by PID). `QNotch.exe --restart` waits up to 10 s for the running instance to release the mutex (used by Settings, Features, Restart now).

Command line verbs: `Program.Main` looks the first argument up in `ModuleList.Verbs` and, on a match, runs that function and exits before any WPF type loads (`QNotch.exe notify ...` talks to the running instance over a pipe). A verb lives in its module's folder, must not touch WPF or shell types, and returns the exit code. Everything else starts the app.

## See your UI without driving the desktop

`QNotch.exe --snapshot <dir> [light]` renders at 2x into `<dir>`: `pill.png` (with the glance strip), `tab-<id>.png` for every tab, `tab-home-edit.png`, `gamebar.png`, `gamebar-corner.png` and `settings-<id>.png` for every settings section (a page taller than the window also gets `settings-<id>-end.png`, scrolled to the bottom, so the Game mode segment toggles are visible), then exits. It runs next to a normal instance (no single-instance lock, window off-screen, nothing is saved, every module is loaded whatever `DisabledModules` says) and writes `snapshot.txt` (hotkey parse checks, errors). When `ctx.Settings.ReadOnly` is true a module should register everything and seed demo data instead of starting its providers (Media shows "Midnight City", Clipboard shows sample entries). Use it after every UI change and look at the PNGs. Every PNG has a `.txt` twin: an indented outline of the visible controls (type, name, `#AutomationId`, checked, selected, disabled) and their text, for checking content and state without reading pixels.

Accessibility names: `IconButton`, `IconToggle` and `TabButton` take their UI Automation name from `ToolTip`, so every glyph button needs a string `ToolTip`. Tabs have the AutomationId `tab-<id>`.

## Folder layout (`src/QNotch`)

| Folder | Owner | Content |
| --- | --- | --- |
| `Core/` | shell | EventBus, SettingsStore, GeneralSettings, Log, Motion, MemoryTrim, Autostart, Paths, UiCulture. Names no module. |
| `Interop/` | shell | `Native` P/Invoke (LibraryImport) used by the shell |
| `Shell/` | shell | NotchWindow, ShellController (IShell, ShellMode), ShellViewModel, HomeView, CardHost, CardLayout, SegmentHost, `EditMode.cs`, `GameMode/`, `Settings/` (General, Features, Hotkeys, Appearance), TrayIcon, HotkeyService, Shortcuts, ForegroundWatcher, Monitors, SettingsWindow, Snapshot |
| `Theme/` | shell | Dark/Light dictionaries, Styles.xaml, Glyphs, ThemeManager, UiKit, Placeholder |
| `Modules/` | shell | `Contracts.cs` (interfaces, descriptors, registries, ModuleContext), `ModuleList.cs` (the only file that names modules) |
| `Modules/<Name>/` | that module's agent | everything for one feature, including its state class |

Modules: Stats, Media, Clipboard, Ai, NoteGithub, FileTray, Notifications, Scheduled, Volume, Pomodoro (the timer; a `Timer` namespace would hide `System.Threading.Timer`), ColorPicker, Search. Game mode and Edit mode are shell features (`Shell/GameMode/`, `Shell/EditMode.cs`).

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

- `ModuleList.All` is the list of `ModuleInfo(Id, Title, Description, Create, Early)`. `ModuleInfo.Id` is the single module id (and the settings file name if you store settings). A module the user turned off (Settings, Features; `GeneralSettings.DisabledModules`, applied on restart) is never created: no timers, hooks, hotkeys, cards, tabs, sections or segments. `Early: true` means the module registers pill or glance segments, so it initializes before the first frame; all others initialize right after it.
- An exception in `Initialize` or `SetCadence` is caught and logged; the app continues. Still, register in `Initialize` before doing risky work.
- Modules never read shell mode to decide refresh rates. React to `SetCadence` only.
- `ModuleContext`: `Bus` (EventBus), `Settings` (SettingsStore), `Hotkeys`, `Shell` (IShell), `Dispatcher`, `Cards`, `Tabs`, `SettingsSections`, `Segments`, `Search`, `Shortcuts`.
- Module state lives in the module: create your own observable state object in `Initialize` (or a field initializer) and pass it to your services and views. The shell never sees it.

### Registries

```csharp
ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", DefaultOrder: 30, () => new MyCardBody(), DefaultVisible: true, ColumnSpan: 1, RowSpan: 1));
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
- Segments are small views the shell hosts outside the panel: `PillLeft` and `PillRight` (the pill: left cluster by Order, then right cluster), `Glance` (the strip under the collapsed pill, shown while any glance element is Visible), `GameBar` (the game bar line). Ids are unique across slots: `<module>.<slot>[.<name>]`; game bar ids are persisted keys (Settings, Game mode toggles them; Title and Hint label the toggle). Factories run once, on the UI thread, on first use (game bar: the first time the bar shows). The factory sets its own DataContext or binds with `Source` (`UiKit.Bind`, `UiKit.BindVisible`), and the element owns its Visibility for data availability ("no battery" collapses the battery). The shell owns Margin (never set your own outer Margin; glance segments get a gap between the visible ones) and, in the game bar, the per-segment user toggle. Font size in the game bar is inherited from the bar. Build segments in code to keep cold start down. Orders in use: pill left 10 (media), pill right 5 (notifications), 7 (timer) and 10 (stats), glance 10 (media) and 20 (notifications), game bar media 10, notifications 15, cpu 20, gpu 30, ram 40, net 50, battery 60, timer 65, clock 70.
- Register inside `Initialize` only (the tab strip is built once, after all modules initialized). Cards, tabs and settings sections: registering an existing id replaces it. Segments are read once (pill and glance at startup, game bar on the first entry into Game mode), so register them only in `Initialize` of an Early module (pill, glance) or any module (game bar). Factories are called once, on the UI thread. A throwing factory shows an error placeholder (a throwing segment is logged and skipped).
- Tab and card factories run at startup idle time (the shell pre-builds and pre-lays-out everything so the first open never stutters): keep them cheap, build heavy content when data arrives.
- Cards: supply only the body; `CardHost` draws the title, hover state and the order badge. Grid: 3 columns of `HomeView.Unit` (218) with `HomeView.Gap` (10) between them, row height `HomeView.RowHeight` (148). A card spanning n columns is `n * 218 + (n - 1) * 10` wide; the body area is that minus 30 horizontally and minus about 50 vertically (card padding, border and title). Default orders in use: stats 10, media 20, volume 25, timer 26, colorpicker 27, clipboard 30, ai-usage 40, note 45, github 50, notifications 60, ai-apps 70, files 80, scheduled 90. Tab orders: home 0, search 5, media 10, clipboard 20, ai 30, files 40, notifications 50, scheduled 60. Settings orders: general 0, features 5, hotkeys 7, appearance 10, gamemode 20, clipboard 30, ai 40, github 50, notifications 60.
- Tab body area is 712 x 322 DIPs. Give tabs their own scrolling (a plain `ScrollViewer` gets the overlay style automatically) and a 19 DIP side inset so content lines up with the header and the Home grid. The shell wraps your tab in its own container (fade/slide on switch): do not rely on your view's `Parent` type. Inactive tabs are `Hidden` (laid out, not rendered): do not run animations or timers because a view is loaded; use `ctx.Shell.ActiveTab` / `TabChanged` plus cadence.
- Settings sections: `UiKit.Page(title)` plus `UiKit.Row(label, hint, control)` gives the standard layout; the window provides the scrolling.
- `TabDescriptor.IsEmpty` (optional `Func<bool>`): return true while the tab has nothing to show. When the panel opens and the last tab is empty, the shell opens Home instead (except during a file drag, which selects the Files tab as the drop target).
- Every view needs explicit empty and "unavailable" states (use `Placeholder.Create(glyph, title, message)`). Never show 0% or an empty list when data is unavailable.

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

`ctx.Shell.Hwnd` is the window handle (for `AddClipboardFormatListener`). Hotkey actions and hooks run on the UI thread. Clipboard reads can block while the source app renders delayed formats: keep the UI-thread read small (formats check, text, a size-capped bitmap) or read on a dedicated STA thread and post the result.

### IShell (what you can ask of the shell)

All members are UI thread only.

- `Hwnd`, `AddHwndHook`.
- `ActiveTab` / `TabChanged`, `SelectTab(id)`, `ClosePanel()`, `OpenSettings(sectionId)`.
- `TryOpenPanel(tabId, lingerMs)`: opens the panel without taking the keyboard, optionally on a tab. Returns false in game mode (nothing opens). When the pointer is elsewhere, the panel closes again after `lingerMs` (at least the leave delay). For something the user must see now (Notifications uses it for errors), never for routine updates.
- `OpenPanelWithKeyboard(tabId)`: opens the panel and takes the keyboard, like the toggle hotkey (Esc or a click elsewhere closes it). Returns false in game mode. Only for an explicit summon by the user: Search uses it for its hotkey, then focuses its box.
- `IsPinned` (get only).
- `HoldOpen()` returns an `IDisposable`: while any hold is alive the panel never auto-closes (pointer leave, focus loss). Wrap `DragDrop.DoDragDrop`, file dialogs, context menus and card drags in `using (ctx.Shell.HoldOpen()) { ... }`. On release the shell asks the OS where the pointer is and closes after the leave delay if it is outside.
- File drops: `FilesDropped(string[] paths)` fires for files dropped anywhere on the panel that no element handled; `FileDragEntered` fires once when a file drag enters the notch. While nobody subscribes, the notch refuses file drops. The shell opens the panel itself when files are dragged over the pill (after the hover dwell).

Everything else (mode, keyboard focus, foreground watcher, monitor, general settings, game mode, edit mode) is shell internal and stays on `ShellController`. `TextBox` and `PasswordBox` inside the panel take the keyboard automatically on mouse down; the keyboard is released when the panel closes or the user clicks elsewhere. Esc closes the panel only while the window has the keyboard.

### Shell features (not modules)

- Game mode (`Shell/GameMode/GameModeController.cs`): detects a fullscreen app (foreground hook, WM_DISPLAYCHANGE, a scoped location hook), debounces entry by 250 ms, and switches the shell to `ShellMode.GameBar` (hover, hotkey, tray and file-drag opening off, window click-through, pill and panel hidden, glance hidden). The bar is built on first entry from the registered `GameBar` segments, each wrapped in a Border whose Visibility is the user toggle (`gamemode.json`, `Segments`: id to bool, missing means on; ). The Ctrl+Alt+G hotkey and the tray menu drive `GameMode.Override` (Auto, ForceOn, ForceOff). `Start()` runs after the first frame.
- Edit mode (`Shell/EditMode.cs`): the header pencil toggles `IsEditMode` (only while the panel is open and `Motion.Enabled`; the panel never auto-closes while it is on). `CardLayout.Hosts` is the live ordered list of `CardHost`; a reorder is persisted with `CardLayout.Move(id, targetId)`, visibility with `SetVisible(id, bool)`.

### Enable switch

Settings, Features has one switch per `ModuleList.All` entry. A switch edits `GeneralSettings.DisabledModules` (general.json) and shows "Restart QNotch to apply your changes." with a "Restart now" button (`QNotch.exe --restart`). At boot `App` skips every disabled module: `Create` is never called, so it has no timers, hooks, hotkeys, cards, tabs, sections or segments and costs nothing. Ids of cards of a disabled module stay in `CardOrder`, so turning the module back on restores its slot. `--snapshot` ignores the list and loads everything.

### Add a new extension

1. Create `Modules/<Name>/` with `<Name>Module.cs` implementing `INotchModule` (and `ICadenceAware` if it refreshes data).
2. Put its state (an `ObservableObject`, set-if-changed properties), providers, views and P/Invoke in the same folder. Nothing in `Core/`, `Shell/` or `Interop/` changes.
3. In `Initialize`, register what it shows: `ctx.Cards`, `ctx.Tabs`, `ctx.SettingsSections` and, for the pill, glance strip or game bar, `ctx.Segments`. Start providers after registering, and honor `ctx.Settings.ReadOnly` (snapshot run: demo data, no providers).
4. Add one line to `ModuleList.All` (`Early: true` only if it registers pill or glance segments), and one to `ModuleList.Verbs` if it has a command line verb.
5. Build, run `QNotch.exe --snapshot <dir>` and look at the PNGs, then measure idle CPU and memory against the performance rules below.

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
Enums serialize as strings. The shell's own settings are `GeneralSettings` (`general.json`): monitor index, hover dwell 120 ms, leave delay 400 ms, pinned, hotkeys, accent, theme, reduce motion, profile, card order/visibility, last tab, start with Windows, `DisabledModules`. It is an ObservableObject persisted by the shell. Secrets (tokens) never go in JSON: use `Windows.Security.Credentials.PasswordVault`.

## Theme

Always use `DynamicResource` for brushes so theme and accent switch live. Keys: `SurfaceBrush`, `SurfaceRaisedBrush`, `WindowBrush`, `CardBrush`, `CardHoverBrush`, `StrokeBrush`, `StrokeStrongBrush`, `ControlBrush`, `ControlHoverBrush`, `ControlPressedBrush`, `TextPrimaryBrush`, `TextSecondaryBrush`, `TextTertiaryBrush`, `AccentBrush`, `AccentHoverBrush`, `AccentSoftBrush`, `OnAccentBrush`, `ToggleKnobOnBrush`, `DangerBrush`, `SuccessBrush`, `WarningBrush`, `ScrollThumbBrush`. Fonts: `UiFont` (Segoe UI Variable), `IconFont` (Segoe Fluent Icons, fallback Segoe MDL2 Assets). Converter: `BoolToVis`. The notch window uses tabular numerals, so changing digits never shift layout.
Styles: TextBlock `Title`, `Caption`, `Muted`, `Glyph`; Button (implicit), `AccentButton`, `IconButton`, `IconToggle` (ToggleButton), `TabButton`, `NavButton`, `SegmentButton` (RadioButton), `ToggleSwitch` (CheckBox); implicit TextBox, PasswordBox, CheckBox, ComboBox, ListBox, ListBoxItem (rounded rows with hover and selection), Slider, ProgressBar, ScrollViewer (overlay scrollbars shown on hover), ScrollBar, ContextMenu, MenuItem, ToolTip. Implicit styles skip subclasses: a class deriving from ScrollViewer (or any styled control) must set `Style = (Style)Application.Current.FindResource(typeof(ScrollViewer))`. Every interactive element has a hover state; keep it that way.
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

Window: fixed 760 x 430 DIPs layered topmost tool window (`WS_EX_LAYERED|TOOLWINDOW|TOPMOST|NOACTIVATE`), top-center of the chosen monitor's full bounds; transparent pixels are click-through (OS per-pixel hit testing). Pill 38 DIPs tall, panel 720 x 380. Re-anchors on `WM_DPICHANGED` and `WM_DISPLAYCHANGE`, reasserts topmost on every foreground change. Hover opens the panel after the dwell, closes after the leave delay unless pinned, a text box holds the keyboard, edit mode is on, or a `HoldOpen` is alive. Ctrl+Alt+N and a tray click toggle the panel and take keyboard focus (Esc or a click elsewhere closes it and focus returns to the previous app); Ctrl+Alt+G cycles the Game mode override (Auto, Force on, Force off). Tray icon: left click toggles, right click menu (Open panel, Settings, Game mode override, Exit). Open animation: 240 ms with a light spring; close 180 ms ease-out; tab switches slide the indicator and fade the new tab in; all skipped when `Motion.Enabled` is false. Cadence: Fast while Expanded, Slow otherwise.
