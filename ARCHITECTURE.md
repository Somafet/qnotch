# QNotch architecture (contract for feature agents)

C# on .NET 10, WPF, `net10.0-windows10.0.22621.0`, x64. Only NuGet dependency: CommunityToolkit.Mvvm. No System.Windows.Forms.
Build: `dotnet build -c Release` from the repo root. Run: `src/QNotch/bin/Release/net10.0-windows10.0.22621.0/win-x64/QNotch.exe`.
Data folder `%APPDATA%\QNotch`, logs in `%APPDATA%\QNotch\logs` (`qnotch.log`, `crash.log`).

## See your UI without driving the desktop

`QNotch.exe --snapshot <dir> [light]` renders at 2x into `<dir>`: `pill.png`, `pill-media.png` (fake now playing, only while no real session exists), `tab-<id>.png` for every tab, `tab-home-edit.png`, `gamebar.png` (your view if the Game mode module set one, else a dummy) and `settings-<id>.png` for every settings section, then exits. It runs next to a normal instance (no single-instance lock, window off-screen, nothing is saved) and writes `snapshot.txt` (hotkey parse checks, errors). Use it after every UI change and look at the PNGs.

## Folder layout (`src/QNotch`)

| Folder | Owner | Content |
| --- | --- | --- |
| `Core/` | shell | EventBus, AppState, SettingsStore, GeneralSettings, Log, Motion, MemoryTrim, Autostart |
| `Core/State/` | one file per module | `<Module>State.cs`: the module's observable state plus a `partial class AppState` adding one property |
| `Interop/` | shell | `Native` P/Invoke (LibraryImport), `Pdh` |
| `Shell/` | shell | NotchWindow, ShellController (IShell), HomeView, CardHost, CardLayout, TrayIcon, HotkeyService, ForegroundWatcher, SettingsWindow, Snapshot |
| `Theme/` | shell | Dark/Light dictionaries, Styles.xaml, Glyphs, ThemeManager, UiKit, Placeholder |
| `Modules/` | shell | `Contracts.cs` (interfaces, descriptors, registries, ModuleContext), `ModuleList.cs` |
| `Modules/<Name>/` | that module's agent | everything for one feature |

Modules: Stats (done), GameMode, Media, Clipboard, Ai, NoteGithub, FileTray, EditMode (stubs that register placeholders; replace the folder contents).

## Rules for feature agents

You own ONLY `Modules/<YourName>/` and `Core/State/<YourName>State.cs`. Do not edit anything else. Sanctioned tiny exceptions:

1. Your `Core/State/<YourName>State.cs` (already exists as a stub, with the partial `AppState` property).
2. A `PackageReference` line in `QNotch.csproj` only if a feature truly cannot be done without it. Say so in your report. Prefer raw P/Invoke and WinRT (the TFM already projects Windows.* APIs).

Need a change in a shared file (a new IShell member, a new theme key, a new Native import)? Do not edit it: put the workaround in your folder and list the request in your report. P/Invoke you need goes in your own class (for example `Modules/Clipboard/ClipboardNative.cs`), never in `Interop/Native.cs`. New files need no csproj edit (globbing). `ModuleList.cs` already lists every module. Styles or templates you need go in a ResourceDictionary inside your folder, merged into your own view's `Resources`.

Namespace gotchas: `System.Windows.Controls.MediaState` collides with `QNotch.Core.MediaState`: add `using MediaState = QNotch.Core.MediaState;`. Inside `namespace QNotch.Modules.Clipboard` the name `Clipboard` resolves to the namespace: write `System.Windows.Clipboard`. `ThemeChoice` is the theme enum (WPF has its own `ThemeMode`). WPF implicit usings exclude `System.IO`/`System.Threading`; the csproj adds them. `Native.GetCursorPos` takes a `POINT`.

## Module contract

```csharp
public sealed class MyModule : INotchModule, ICadenceAware   // ICadenceAware optional
{
    public string Id => "mymodule";                         // also the settings file name
    public void Initialize(ModuleContext ctx) { ... }       // UI thread, once, window handle exists
    public void SetCadence(Cadence c) { ... }               // Fast: panel open. Slow: collapsed or game bar.
}
```

- An exception in `Initialize` or `SetCadence` is caught and logged; the app continues. Still, register in `Initialize` before doing risky work.
- Modules never read shell mode to decide refresh rates. React to `SetCadence` only (`ctx.Shell.ModeChanged` exists for the Game mode module).
- `ModuleContext`: `State` (AppState), `Bus` (EventBus), `Settings` (SettingsStore), `Hotkeys`, `Shell` (IShell), `Dispatcher`, `Cards`, `Tabs`, `SettingsSections`, `CardLayout`.

### Registries

```csharp
ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", DefaultOrder: 30, () => new MyCardBody(), DefaultVisible: true, ColumnSpan: 1, RowSpan: 1));
ctx.Tabs.Register(new TabDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, Order: 20, () => new MyTab()));
ctx.SettingsSections.Register(new SettingsSectionDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 30, () => MySettings.Create()));
```

- Register inside `Initialize` only (the tab strip is built once, after all modules initialized). Registering an existing id replaces it. Factories are called once, on the UI thread. A throwing factory shows an error placeholder.
- Tab and card factories run at startup idle time (the shell pre-builds and pre-lays-out everything so the first open never stutters): keep them cheap, build heavy content when data arrives.
- Cards: supply only the body; `CardHost` draws the title, hover state and the order badge. Grid: 3 columns of `HomeView.Unit` (218) with `HomeView.Gap` (10) between them, row height `HomeView.RowHeight` (148). A card spanning n columns is `n * 218 + (n - 1) * 10` wide; the body area is that minus 30 horizontally and minus about 50 vertically (card padding, border and title). Default orders in use: stats 10, media 20, clipboard 30, ai-usage 40, github 50, note 60, ai-apps 70, files 80. Tab orders: home 0, media 10, clipboard 20, ai 30, files 40. Settings orders: general 0, appearance 10, gamemode 20, clipboard 30, ai 40, github 50.
- Tab body area is 712 x 322 DIPs. Give tabs their own scrolling (a plain `ScrollViewer` gets the overlay style automatically) and a 19 DIP side inset so content lines up with the header and the Home grid. The shell wraps your tab in its own container (fade/slide on switch): do not rely on your view's `Parent` type. Inactive tabs are `Hidden` (laid out, not rendered): do not run animations or timers because a view is loaded; use `ctx.Shell.ActiveTab` / `TabChanged` plus cadence.
- Settings sections: `UiKit.Page(title)` plus `UiKit.Row(label, hint, control)` gives the standard layout; the window provides the scrolling.
- Every view needs explicit empty and "unavailable" states (use `Placeholder.Create(glyph, title, message)`). Never show 0% or an empty list when data is unavailable.

### Hotkeys and window messages

```csharp
ctx.Hotkeys.Register("Alt+1", () => LaunchSlot(1));           // gesture string (KeyGestureConverter syntax), returns false if taken
ctx.Hotkeys.Register(ModifierKeys.Alt, Key.D2, () => ...);
HwndSourceHook hook = (nint hwnd, int msg, nint w, nint l, ref bool handled) => { ... return 0; };
ctx.Shell.AddHwndHook(hook);                                     // e.g. WM_CLIPBOARDUPDATE, WM_DISPLAYCHANGE; RemoveHwndHook(hook) to detach
```
`ctx.Shell.Hwnd` is the window handle (for `AddClipboardFormatListener`). Hotkey actions and hooks run on the UI thread. Clipboard reads can block while the source app renders delayed formats: keep the UI-thread read small (formats check, text, a size-capped bitmap) or read on a dedicated STA thread and post the result.

### IShell (what you can ask of the shell)

All members are UI thread only.

- `Mode` / `ModeChanged`, `OpenPanel/ClosePanel/TogglePanel`, `SelectTab(id)`, `ActiveTab` / `TabChanged`, `OpenSettings(sectionId)`, `IsPinned`, `General` (live GeneralSettings).
- `HoldOpen()` returns an `IDisposable`: while any hold is alive the panel never auto-closes (pointer leave, focus loss). Wrap `DragDrop.DoDragDrop`, file dialogs, context menus and card drags in `using (ctx.Shell.HoldOpen()) { ... }`. On release the shell asks the OS where the pointer is and closes after the leave delay if it is outside.
- `RequestKeyboardFocus()`: makes the window activatable and takes the foreground. `TextBox` and `PasswordBox` inside the panel do it automatically on mouse down. The keyboard is released (and the foreground returned to the previous app) when the panel closes or the user clicks elsewhere. Esc closes the panel only while the window has the keyboard.
- File drops: `FilesDropped(string[] paths)` fires for files dropped anywhere on the panel that no element handled; `FileDragEntered` fires once when a file drag enters the notch. While nobody subscribes, the notch refuses file drops. The shell opens the panel itself when files are dragged over the pill (after the hover dwell).
- `Foreground` (ForegroundWatcher): `Changed(hwnd)` on every foreground change (SetWinEventHook, no polling), including QNotch's own windows. It does not report size changes of the foreground window; if you need "game switched to fullscreen after launch", add your own out-of-context WinEvent hook in your folder (static `[UnmanagedCallersOnly]` callback, like ForegroundWatcher) scoped to the foreground process.
- `Hwnd`, `Monitor` (HMONITOR hosting the notch), `AddHwndHook` / `RemoveHwndHook`.
- `GameModeOverride` (+ event; Auto, ForceOn, ForceOff). The shell's hotkey (Ctrl+Alt+G) and tray menu drive it; the tray tooltip shows it and whether the game bar is showing.

Game mode plumbing: `SetGameBarActive(bool)` switches the shell to `ShellMode.GameBar` (hover, hotkey, tray and file-drag opening off, window click-through, pill and panel hidden, glance hidden) and back (restores pill, opacity, click-through and, if it was open and pinned, the panel). `SetGameBarView(UIElement?)` hosts your bar; it sizes itself (natural width) and is centered vertically in the bar height. `SetGameBarLayout(height, opacity, offsetX, offsetY)`: DIPs; the offsets move the bar center from the monitor's top-center (positive is right/down) and are clamped so the bar stays on screen, so large values reach the corners; with `offsetY > 0` the bar is drawn as a free-floating capsule. `SetClickThrough(bool)` toggles WS_EX_TRANSPARENT directly. Set the view and layout before `SetGameBarActive(true)`; both are kept across game sessions.

Edit mode plumbing: the header pencil toggles `IShell.IsEditMode` (only allowed while the panel is open and `Motion.Enabled`; the panel never auto-closes while it is on). `ctx.CardLayout.Hosts` is the live ordered list of `CardHost` (raises `HostsChanged` after every rebuild); each host has `CardId`, `OrderNumber` (fixed 1-based slot, badge shown when `IsEditMode`), and a free `RenderTransform`. Hosts sit in a `WrapPanel` inside `HomeView` (a ScrollViewer). Persist a reorder with `CardLayout.Move(id, targetId)` (moves `id` into the slot of `targetId`); `SetVisible(id, bool)` for visibility. HomeView rebuilds itself on `CardLayout.Changed` (hosts are reused, not recreated).

## State and threading

- `AppState` (`ctx.State`) is the single model: `Stats`, `Media` in core; other modules add their own via `Core/State/<Module>State.cs`. All properties are `[ObservableProperty]` (set-if-changed). Only touch state on the UI thread.
- Providers do all I/O and sampling on the thread pool and hand results over the bus:

```csharp
// background thread
ctx.Bus.Post(new ClipboardCaptured(text));                    // typed event, any thread, never blocks
ctx.Bus.Run(() => ctx.State.Media.Title = title);             // or run an action on the UI thread
// Initialize (UI thread)
ctx.Bus.Subscribe<ClipboardCaptured>(e => ctx.State.Clipboard.Add(e));
```
  Posts are coalesced into one dispatcher callback. There is no polling anywhere; use OS events, or a one-shot `System.Threading.Timer` you re-arm for cadence.
- `MediaState` is filled by the Media module (`IsAvailable`, `HasSession`, `Title`, `Artist`, `Artwork` (frozen ImageSource), `IsPlaying`, `Position`, `Duration`, `LastTimelineUpdate`, `Sessions`, `SelectedSessionId`, `Controls` (`IMediaControls`), plus `PlayPauseCommand`, `NextCommand`, `PreviousCommand`, `SelectSessionCommand`). The pill (artwork, title, artist) and the glance strip already bind to it. Media agent: implement `IMediaControls`, assign `State.Media.Controls`, keep `HasSession`/`IsPlaying` accurate (the glance strip appears when both are true and the panel is closed).
- `StatsState` texts are ready to render. Game mode agent: bind your bar to `State.Stats` (`CpuText`, `GpuText` ("n/a" when unavailable), `RamText`, `NetDownText`, `NetUpText`, `BatteryText`, `BatteryGlyph`, `HasBattery`, `Clock`) and `State.Media.NowPlayingText`.

## Settings

One JSON file per module, so nobody edits a shared class:

```csharp
public sealed class MediaSettings { public bool ShowArtwork { get; set; } = true; }
var s = ctx.Settings.Get<MediaSettings>("media");   // cached live instance, defaults if missing or corrupt
s.ShowArtwork = false;
ctx.Settings.Save("media", s);                       // debounced 500 ms, atomic (temp file then move)
```
Enums serialize as strings. The shell's own settings are `GeneralSettings` (`general.json`): monitor index, hover dwell 120 ms, leave delay 400 ms, pinned, hotkeys, accent, theme, reduce motion, profile, card order/visibility, last tab, start with Windows. It is an ObservableObject: bind to `ctx.Shell.General`; the shell persists changes automatically. Secrets (tokens) never go in JSON: use `Windows.Security.Credentials.PasswordVault`.

## Theme

Always use `DynamicResource` for brushes so theme and accent switch live. Keys: `SurfaceBrush`, `SurfaceRaisedBrush`, `WindowBrush`, `CardBrush`, `CardHoverBrush`, `StrokeBrush`, `StrokeStrongBrush`, `ControlBrush`, `ControlHoverBrush`, `ControlPressedBrush`, `TextPrimaryBrush`, `TextSecondaryBrush`, `TextTertiaryBrush`, `AccentBrush`, `AccentHoverBrush`, `AccentSoftBrush`, `OnAccentBrush`, `ToggleKnobOnBrush`, `DangerBrush`, `SuccessBrush`, `WarningBrush`, `ScrollThumbBrush`. Fonts: `UiFont` (Segoe UI Variable), `IconFont` (Segoe Fluent Icons, fallback Segoe MDL2 Assets). Converter: `BoolToVis`. The notch window uses tabular numerals, so changing digits never shift layout.
Styles: TextBlock `Title`, `Caption`, `Muted`, `Glyph`; Button (implicit), `AccentButton`, `IconButton`, `IconToggle` (ToggleButton), `TabButton`, `NavButton`, `SegmentButton` (RadioButton), `ToggleSwitch` (CheckBox); implicit TextBox, PasswordBox, CheckBox, ComboBox, ListBox, ListBoxItem (rounded rows with hover and selection), Slider, ProgressBar, ScrollViewer (overlay scrollbars shown on hover), ScrollBar, ContextMenu, MenuItem, ToolTip. Implicit styles skip subclasses: a class deriving from ScrollViewer (or any styled control) must set `Style = (Style)Application.Current.FindResource(typeof(ScrollViewer))`. Every interactive element has a hover state; keep it that way.
Glyph constants: `Theme/Glyphs.cs`. Code helpers: `UiKit.Page/Row/Toggle/Text/Glyph/Header`, `Placeholder.Create`.
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
