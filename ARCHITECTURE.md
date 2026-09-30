# QNotch architecture (contract for feature agents)

C# on .NET 10, WPF, `net10.0-windows10.0.22621.0`, x64. Only NuGet dependency: CommunityToolkit.Mvvm. No System.Windows.Forms.
Build: `dotnet build -c Release` from the repo root. Run: `src/QNotch/bin/Release/net10.0-windows10.0.22621.0/win-x64/QNotch.exe`.
Data folder `%APPDATA%\QNotch`, logs in `%APPDATA%\QNotch\logs` (`qnotch.log`, `crash.log`).

## Folder layout (`src/QNotch`)

| Folder | Owner | Content |
| --- | --- | --- |
| `Core/` | shell | EventBus, AppState, SettingsStore, GeneralSettings, Log, Motion, MemoryTrim, Autostart |
| `Core/State/` | one file per module | `<Module>State.cs`: the module's observable state plus a `partial class AppState` adding one property |
| `Interop/` | shell | `Native` P/Invoke (LibraryImport), `Pdh` |
| `Shell/` | shell | NotchWindow, ShellController (IShell), HomeView, CardHost, CardLayout, TrayIcon, HotkeyService, ForegroundWatcher, SettingsWindow |
| `Theme/` | shell | Dark/Light dictionaries, Styles.xaml, Glyphs, ThemeManager, UiKit, Placeholder |
| `Modules/` | shell | `Contracts.cs` (interfaces, descriptors, registries, ModuleContext), `ModuleList.cs` |
| `Modules/<Name>/` | that module's agent | everything for one feature |

Modules: Stats (done), GameMode, Media, Clipboard, Ai, NoteGithub, FileTray, EditMode (stubs that register placeholders; replace the folder contents).

## Rules for feature agents

You own ONLY `Modules/<YourName>/` and `Core/State/<YourName>State.cs`. Do not edit anything else. Sanctioned tiny exceptions:

1. Your `Core/State/<YourName>State.cs` (already exists as a stub, with the partial `AppState` property).
2. A `PackageReference` line in `QNotch.csproj` only if a feature truly cannot be done without it. Say so in your report. Prefer raw P/Invoke and WinRT (the TFM already projects Windows.* APIs).

Need a change in a shared file (a new IShell member, a new theme key, a new Native import)? Do not edit it: put the workaround in your folder and list the request in your report. P/Invoke you need goes in your own class (for example `Modules/Clipboard/ClipboardNative.cs`), never in `Interop/Native.cs`. New files need no csproj edit (globbing). `ModuleList.cs` already lists every module.

Namespace gotchas: `System.Windows.Controls.MediaState` collides with `QNotch.Core.MediaState`: add `using MediaState = QNotch.Core.MediaState;`. Inside `namespace QNotch.Modules.Clipboard` the name `Clipboard` resolves to the namespace: write `System.Windows.Clipboard`. `ThemeChoice` is the theme enum (WPF has its own `ThemeMode`). WPF implicit usings exclude `System.IO`/`System.Threading`; the csproj adds them.

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
- Modules never read shell mode. React to `SetCadence` only (`ctx.Shell.ModeChanged` exists for the Game mode module).
- `ModuleContext`: `State` (AppState), `Bus` (EventBus), `Settings` (SettingsStore), `Hotkeys`, `Shell` (IShell), `Dispatcher`, `Cards`, `Tabs`, `SettingsSections`, `CardLayout`.

### Registries

```csharp
ctx.Cards.Register(new CardDescriptor("clipboard", "Clipboard", DefaultOrder: 30, () => new MyCardBody(), DefaultVisible: true, ColumnSpan: 1, RowSpan: 1));
ctx.Tabs.Register(new TabDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, Order: 20, () => new MyTab()));
ctx.SettingsSections.Register(new SettingsSectionDescriptor("clipboard", "Clipboard", Glyphs.Clipboard, 30, () => new MySettings()));
```

- Registering an existing id replaces it. Do it inside `Initialize`. Factories are called lazily, once, on the UI thread. A throwing factory shows an error placeholder.
- Cards: supply only the body; `CardHost` draws the title, hover state, and the order badge. Grid: 3 columns (218 px each, 10 px gap), row height 148. Card id, default order and ColumnSpan/RowSpan are yours; the user's order and visibility live in general.json (`CardLayout`). Default orders in use: stats 10, media 20, clipboard 30, ai-usage 40, github 50, note 60, ai-apps 70, files 80. Tab orders: home 0, media 10, clipboard 20, ai 30, files 40. Settings orders: general 0, appearance 10, gamemode 20, clipboard 30, ai 40, github 50.
- Tab body area is about 712 x 324 DIPs. Give tabs their own scrolling.
- Every view needs explicit empty and "unavailable" states (use `Placeholder.Create(glyph, title, message)`). Never show 0% or an empty list when data is unavailable.

### Hotkeys and window messages

```csharp
ctx.Hotkeys.Register("Alt+1", () => LaunchSlot(1));           // gesture string, returns false if taken
ctx.Hotkeys.Register(ModifierKeys.Alt, Key.D2, () => ...);
ctx.Shell.AddHwndHook((nint hwnd, int msg, nint w, nint l, ref bool handled) => { ... return 0; });  // e.g. WM_CLIPBOARDUPDATE
```
`ctx.Shell.Hwnd` is the window handle (for `AddClipboardFormatListener`). Hotkey actions and hooks run on the UI thread.

### IShell (what you can ask of the shell)

`Mode` / `ModeChanged`, `OpenPanel/ClosePanel/TogglePanel`, `SelectTab(id)`, `OpenSettings(sectionId)`, `IsPinned`, `IsEditMode` / `EditModeChanged`, `RequestKeyboardFocus()` (TextBox and PasswordBox in the panel call it automatically on mouse down), `GameModeOverride` (+ event; Auto, ForceOn, ForceOff), `Foreground` (ForegroundWatcher: `Changed(hwnd)` without polling), `Hwnd`, `AddHwndHook`, `General` (live GeneralSettings).

Game mode plumbing: `SetGameBarActive(bool)` switches the shell to `ShellMode.GameBar` (hover and hotkey opening off, window click-through, pill and panel hidden) and back (restores pill, opacity, click-through and, if it was open and pinned, the panel). `SetGameBarView(UIElement?)` hosts your bar, which sizes itself (natural width). `SetGameBarLayout(height, opacity, offsetX, offsetY)` (DIPs, offsets from top-center, positive is right/down; the offset moves the whole 760 x 430 window and is clamped to the monitor). `SetClickThrough(bool)` toggles WS_EX_TRANSPARENT directly.

Edit mode plumbing: the header pencil toggles `IShell.IsEditMode` (only allowed while the panel is open and `Motion.Enabled`). `ctx.CardLayout.Hosts` is the live ordered list of `CardHost` (raises `HostsChanged` after every rebuild); each host has `CardId`, `OrderNumber` (fixed 1-based slot, badge shown when `IsEditMode`), and a free `RenderTransform`. Persist a reorder with `CardLayout.Move(id, targetId)` (moves `id` into the slot of `targetId`); `SetVisible(id, bool)` for visibility. HomeView rebuilds itself on `CardLayout.Changed`.

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
- `MediaState` is filled by the Media module (`IsAvailable`, `HasSession`, `Title`, `Artist`, `Artwork` (frozen ImageSource), `IsPlaying`, `Position`, `Duration`, `LastTimelineUpdate`, `Sessions`, `Controls` (`IMediaControls`)). The pill, glance strip and Game bar already bind to it. Media agent: implement `IMediaControls`, assign `State.Media.Controls`, keep `HasSession`/`IsPlaying` accurate (the glance strip appears when both are true).
- `StatsState` texts are ready to render. Game mode agent: bind your bar to `State.Stats` (`CpuText`, `GpuText` ("n/a" when unavailable), `RamText`, `NetDownText`, `NetUpText`, `BatteryText`, `BatteryGlyph`, `HasBattery`, `Clock`) and `State.Media.NowPlayingText`.

## Settings

One JSON file per module, so nobody edits a shared class:

```csharp
public sealed class MediaSettings { public bool ShowArtwork { get; set; } = true; }
var s = ctx.Settings.Get<MediaSettings>("media");   // cached live instance, defaults if missing or corrupt
s.ShowArtwork = false;
ctx.Settings.Save("media", s);                       // debounced 500 ms, atomic (temp file then move)
```
Enums serialize as strings. The shell's own settings are `GeneralSettings` (`general.json`): monitor index, hover dwell 120 ms, leave delay 400 ms, pinned, hotkeys, accent, theme, reduce motion, profile, card order/visibility, start with Windows. It is an ObservableObject: bind to `ctx.Shell.General`; the shell persists changes automatically.

## Theme

Always use `DynamicResource` for brushes so theme and accent switch live. Keys: `SurfaceBrush`, `SurfaceRaisedBrush`, `WindowBrush`, `CardBrush`, `CardHoverBrush`, `StrokeBrush`, `StrokeStrongBrush`, `ControlBrush`, `ControlHoverBrush`, `ControlPressedBrush`, `TextPrimaryBrush`, `TextSecondaryBrush`, `TextTertiaryBrush`, `AccentBrush`, `AccentHoverBrush`, `AccentSoftBrush`, `OnAccentBrush`, `DangerBrush`, `SuccessBrush`, `WarningBrush`, `ScrollThumbBrush`. Fonts: `UiFont` (Segoe UI Variable), `IconFont` (Segoe Fluent Icons, fallback Segoe MDL2 Assets). Converter: `BoolToVis`.
Styles: TextBlock `Title`, `Caption`, `Muted`, `Glyph`; Button (implicit), `AccentButton`, `IconButton`, `IconToggle` (ToggleButton), `TabButton`, `NavButton`, `SegmentButton` (RadioButton), `ToggleSwitch` (CheckBox); implicit TextBox, ComboBox, Slider, ProgressBar, ScrollBar, ContextMenu, MenuItem, ToolTip. Every interactive element has a hover state; keep it that way.
Glyph constants: `Theme/Glyphs.cs`. Code helpers: `UiKit.Page/Row/Toggle/Text/Glyph`, `Placeholder.Create`.
Spacing scale: 4, 8, 12, 16, 24. Radii: 6 chips, 8 controls, 14 cards, 26 panel. Never use an em dash in UI text or docs.

## Performance rules (hard)

- Idle CPU at or under 0.1% while collapsed. Nothing faster than 1 s while collapsed; clock on the minute boundary; event-driven wherever Windows offers events.
- Zero repaints while collapsed and idle: no forever-running storyboards or animated effects; unchanged data must not raise property changes (properties are set-if-changed; format text in the provider, not in a per-tick converter).
- No `DropShadowEffect` or `BlurEffect` on large or animated elements. Prefer frozen brushes and images (`Freeze()`; decode thumbnails with `DecodePixelWidth`).
- Animations: check `Motion.Enabled` (user setting and OS animation setting) and skip them when false. Animate transforms and opacity, not layout, and remove the animation when done (no HoldEnd forever).
- Providers never block the UI thread. Anything over about 2 ms goes to the thread pool.
- Panel content is pre-built and pre-laid-out at startup; the panel is `Collapsed` while closed. Keep card factories cheap and do not build heavy content until data arrives.
- Resident memory under 80 MB: the shell trims once after startup and after each panel close (`MemoryTrim`). Do not cache unbounded data.

## Shell behaviour summary

Window: fixed 760 x 430 DIPs layered topmost tool window (`WS_EX_TOOLWINDOW|TOPMOST|NOACTIVATE`), top-center of the chosen monitor's full bounds; transparent pixels are click-through. Re-anchors on `WM_DPICHANGED` and `WM_DISPLAYCHANGE`, reasserts topmost on foreground changes. Hover opens the panel after the dwell, closes after the leave delay (not while pinned or while a text box holds keyboard focus), Esc closes, Ctrl+Alt+N toggles, Ctrl+Alt+G cycles the Game mode override (Auto, Force on, Force off). Tray icon: click toggles, right click menu (Open panel, Settings, Game mode override, Exit). Cadence: Fast while Expanded, Slow otherwise.
