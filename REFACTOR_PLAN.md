# Extension-boundary refactor plan

Status: done (Core stage 263b897, 715bbe6, 1fad5a0; Integrate review and verification pass on top). Deviations from this plan: `SegmentHost` is an instance class with a per-id cache (the shell and the game mode controller each own one) instead of a static helper; `UiKit.Bind` and `UiKit.BindVisible` were added for the code-built segments; the legacy game bar flag migration lives in `GameModeSettings.MigrateLegacy()`; the snapshot tool also writes `settings-<id>-end.png` for scrollable pages. No temporary shims remain.

Structural only: visuals, behaviour and the performance baseline stay the same or improve. Six extensions (Stats, Media, Clipboard, Ai, NoteGithub, FileTray) sit on a shell that knows none of them by name except `Modules/ModuleList.cs`. No DLL plugin loading.

## Coupling today (what this removes)

| Leak | Where |
| --- | --- |
| Core -> Modules | `Core/State/AiState.cs` (`using QNotch.Modules.Ai`), `Core/State/NoteGithubState.cs` (`using QNotch.Modules.NoteGithub`), one `partial AppState` property per module |
| Shell binds module state | `NotchWindow.xaml` pill and glance bind `State.Media.*` / `State.Stats.*`; `ShellController` watches `State.Media` / `State.Stats` to re-measure the pill and drive the glance |
| Shell names modules | `App.Boot`: `m is StatsModule or MediaModule` picks the early modules |
| Snapshot touches module state | `Snapshot.Run` fakes `state.Media` for `pill-media.png` |
| Shell features dressed as modules | `Modules/GameMode` (drives `SetGameBarActive/View/Layout`, `SetClickThrough`, reads `Stats`/`Media`), `Modules/EditMode` (drives `CardLayout.Hosts`) |
| Module to shell UI helper | `QNotch.Shell.Settings.GeneralSection.Toggle(bool, Action<bool>)` used by Ai and GameMode |

## Target contracts

### Segments (`Modules/Contracts.cs`)

```csharp
public enum SegmentSlot { PillLeft, PillRight, Glance, GameBar }

/// Small views the shell hosts outside the panel. Factory: called once, UI thread; sets its own DataContext (or binds with Source).
/// The element owns its Visibility for data availability ("no battery" collapses the battery). The shell owns Margin and,
/// in GameBar, the per-segment user toggle. Title and Hint: GameBar only (Settings, Game mode, Segments).
public sealed record SegmentDescriptor(string Id, SegmentSlot Slot, int Order, Func<FrameworkElement> Factory,
    string Title = "", string? Hint = null) : IRegistryItem;
```

- `ModuleContext.Segments` is a `Registry<SegmentDescriptor>`. Ids are unique across slots: `<module>.<slot>[.<name>]`. GameBar ids are persisted keys.
- Registered segments:

| Id | Slot | Order | Visibility bound to | Title / Hint |
| --- | --- | --- | --- | --- |
| `media.pill` | PillLeft | 10 | `MediaState.HasSession` | |
| `stats.pill` | PillRight | 10 | always (battery part: `HasBattery`) | |
| `media.glance` | Glance | 10 | `MediaState.IsNowPlaying` | |
| `media.game` | GameBar | 10 | `MediaState.IsNowPlaying` | Now playing / Title and artist, only while something plays. |
| `stats.game.cpu` | GameBar | 20 | always | CPU |
| `stats.game.gpu` | GameBar | 30 | `StatsState.GpuAvailable` | GPU / Only when the system reports GPU usage. |
| `stats.game.ram` | GameBar | 40 | always | Memory |
| `stats.game.net` | GameBar | 50 | always | Network |
| `stats.game.battery` | GameBar | 60 | `StatsState.HasBattery` | Battery / Only on devices with a battery. |
| `stats.game.clock` | GameBar | 70 | always | Clock |

  Order 65 is left free for a future frame-time segment (replaces `GameModeState.FpsText/ShowFps`, which are deleted).
- `stats.pill` is one element holding CPU, RAM, net, battery and clock exactly as today's XAML (same MinWidths, runs, sizes). Media segments move the accent music glyph of the glance strip into `media.glance`.
- `MediaState` gains `[ObservableProperty] bool _isNowPlaying` = `HasSession && IsPlaying && Title.Length > 0`, kept in sync from the generated `OnHasSessionChanged/OnIsPlayingChanged/OnTitleChanged` partials (set-if-changed). Replaces `GameModeModule.RefreshSegments` media logic; the glance no longer shows an empty strip for a title-less session (small improvement).

Shell hosting (bind once, nothing per tick):

- `NotchWindow.xaml`: the pill content becomes `<StackPanel x:Name="PillStrip" Orientation="Horizontal" Margin="16,0,18,1" VerticalAlignment="Center"/>` inside `PillLayer` (add `MinWidth="96"` to `PillLayer` so a pill with Stats and Media off stays a hover target). The glance border keeps its chrome and hosts `<StackPanel x:Name="GlanceStrip" Orientation="Horizontal" VerticalAlignment="Center"/>`. `GameBarHost` stays a ContentPresenter.
- `Shell/SegmentHost.cs` (internal static): `FrameworkElement? Build(SegmentDescriptor d)` (factory in try/catch, logs and returns null on failure) plus an id -> element cache owned by the caller, so a factory never runs twice.
- `ShellController.BuildPill()` (in `Start()`, before `InitPill`, and again on `Segments.Changed`): children = PillLeft by Order, then PillRight by Order. Shell sets `el.Margin`: PillLeft `(0,0,18,0)`, PillRight `(0,0,12,0)`, the last child of the strip `0`. A collapsed element drops its margin, so no wrappers are needed and today's pixels are reproduced. Segments must not set their own outer Margin.
- Pill width: `PillStrip.SizeChanged += (_, _) => _w.InvalidatePill()` replaces the Media/Stats `PropertyChanged` watchers (fewer calls than today: MinWidths keep digit changes from resizing).
- Glance: `BuildGlance()` fills `GlanceStrip`; for each element `DependencyPropertyDescriptor.FromProperty(UIElement.VisibilityProperty, typeof(UIElement)).AddValueChanged(el, ...)` once. `UpdateGlance() => Vm.ShowGlance = _mode == ShellMode.Collapsed && GlanceStrip.Children.OfType<UIElement>().Any(e => e.Visibility == Visibility.Visible)`.
- Game bar: built by `GameModeController.EnsureBar()` on first entry only (and on `Segments.Changed` once built): a `StackPanel { Orientation = Horizontal, Margin = (12,0,0,0), VerticalAlignment = Center, IsHitTestVisible = false, Focusable = false }` (the old `GameBar.xaml` root). Each GameBar segment: shell sets `el.Margin = (0,0,12,0)` and wraps it in a `Border` whose Visibility is the user toggle. FontSize is set on the panel from the height (`Math.Clamp(Math.Round(h * 0.5), 10, 16)`), segments inherit it.
- GPU sampling while the bar shows GPU: Stats subscribes `IsVisibleChanged` on its `stats.game.gpu` element inside the factory and writes a module-private `volatile bool _gpuWanted`. `IsVisible` is true only while the bar is shown, the toggle is on and `GpuAvailable`, which is exactly today's `GpuWanted = _active && ShowGpu`. `StatsState.GpuWanted` is deleted.

### Module list and enable switch

```csharp
// Contracts.cs
public sealed record ModuleInfo(string Id, string Title, string Description, Func<INotchModule> Create, bool Early = false);

// ModuleList.cs: the one file naming modules
public static readonly IReadOnlyList<ModuleInfo> All =
[
    new("stats", "System stats", "CPU, memory, network, battery and clock in the pill, the System card and the game bar.", () => new StatsModule(), Early: true),
    new("media", "Now playing", "Track, artwork and controls for anything that plays media.", () => new MediaModule(), Early: true),
    new("clipboard", "Clipboard history", "Text and images you copy, kept in memory.", () => new ClipboardModule()),
    new("ai", "AI apps and usage", "Alt+1 to Alt+6 shortcuts and usage limits for Claude Code and Codex.", () => new AiModule()),
    new("notegithub", "Note and GitHub", "A quick note and your GitHub contribution graph.", () => new NoteGithubModule()),
    new("filetray", "File tray", "Drop files on the notch to keep them within reach.", () => new FileTrayModule()),
];
```

- `Early`: the module registers pill or glance segments and initializes before the first frame (replaces the `is StatsModule or MediaModule` check). `INotchModule.Id` stays and must equal `ModuleInfo.Id` (log a warning on mismatch).
- `GeneralSettings.DisabledModules: List<string>` (general.json, default empty). Every module can be disabled. A disabled module is never constructed (`Create` is not called), so no timers, hooks, hotkeys, cards, tabs, sections or segments exist for it. `--snapshot` ignores the list and loads everything.
- Boot: `var bootDisabled = gs.DisabledModules.ToHashSet(StringComparer.OrdinalIgnoreCase)`; `Log.Info("Modules: stats, media, ... (off: ai)")`.
- UI: new shell section `Shell/Settings/FeaturesSection.cs`, id `features`, title "Features", glyph `Glyphs.Apps = ""`, order 5. Intro (Muted): "Turn off what you do not use. A feature that is off is never loaded and costs nothing." One `UiKit.Row(info.Title, info.Description, UiKit.Toggle(on, set))` per module; a toggle edits `DisabledModules` and calls `store.Save("general", gs)`. Below the rows, a restart bar (ControlBrush rounded border, hidden while the current set equals `bootDisabled`): text "Restart QNotch to apply your changes." plus an `AccentButton` "Restart now".
  `Create(GeneralSettings gs, SettingsStore store, IReadOnlyList<ModuleInfo> modules, IReadOnlySet<string> bootDisabled, Action restart)`.
- Restart: `App.Restart()`: `Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "--restart") { UseShellExecute = false })` (inherits QNOTCH_* env vars) then `Shutdown()`. In `OnStartup`, when the mutex is taken and `--restart` is present, wait for it: `try { ok = m.WaitOne(10_000); } catch (AbandonedMutexException) { ok = true; }`; exit if not ok. The old instance releases the mutex last in `OnExit` (after hotkeys and tray are gone), so the new one never finds its hotkeys taken.

### Parallel-run env vars

- `Core/Paths.cs`: `DataDir = QNOTCH_DATA_DIR` (full path, created) when set and non-empty, else `%APPDATA%\QNotch`. Logs follow (`LogDir` is under `DataDir`).
- `App.OnStartup`: mutex name `@"Local\QNotch.SingleInstance" + (QNOTCH_INSTANCE is { Length: > 0 } i ? "." + i : "")`.
- Documented in README (Data folder) and ARCHITECTURE (test runs). PasswordVault and the Run key stay per user (not affected).

### Module state moves (constructor injection, no AppState)

Each module creates its own state instance and passes it to its services and views. `ModuleContext.State`, `Core/AppState.cs` and `Core/State/` are deleted. `ShellMode` moves to `Shell/ShellController.cs` (namespace `QNotch.Shell`), `GameModeOverride` to `Shell/GameMode/GameModeSettings.cs`.

| From | To (namespace `QNotch.Modules.<Name>`) | Wiring change |
| --- | --- | --- |
| `Core/State/StatsState.cs` | `Modules/Stats/StatsState.cs` | `StatsModule`: `readonly StatsState _st = new()`; drop `GpuWanted` |
| `Core/State/MediaState.cs` (+ `MediaSessionInfo`, `IMediaControls`) | `Modules/Media/MediaState.cs` | `MediaModule`: `readonly MediaState _m = new()`; add `IsNowPlaying`; drop every `using MediaState = QNotch.Core.MediaState` alias (the local type wins inside the namespace) |
| `Core/State/AiState.cs` | `Modules/Ai/AiState.cs` | `AiModule`: `readonly AiState _st = new()` replaces `St => _ctx.State.Ai` |
| `Core/State/ClipboardState.cs` (+ `ClipEntry`, `ClipKind`, `ClipFilter`) | `Modules/Clipboard/ClipboardState.cs` | `_st = new()`; `ClipboardTab.xaml` `xmlns:core="clr-namespace:QNotch.Core"` becomes `xmlns:local="clr-namespace:QNotch.Modules.Clipboard"` (update `core:` prefixes) |
| `Core/State/FileTrayState.cs` (+ `TrayItem`) | `Modules/FileTray/FileTrayState.cs` | `FileTrayModule` creates it; `FileTrayService(ModuleContext ctx, FileTrayState state)` |
| `Core/State/NoteGithubState.cs` (+ `NoteStatus`, `GithubStatus`) | `Modules/NoteGithub/NoteGithubState.cs` | `NoteGithubModule` creates it; `NoteStore(ctx, state)`, `GithubService(ctx, state)`; `NoteCard.xaml` xmlns `core` -> `local` |
| `Core/State/GameModeState.cs` | deleted | folded into `GameModeController` (`IsActive`, `Reason`, `StatusChanged`) |

Use `git mv` so history follows. Remove the trailing `partial class AppState` block from each moved file. `UiKit.Toggle(bool value, Action<bool> set)` (Theme) replaces `GeneralSection.Toggle`; update Ai, Appearance, GameMode callers and delete the old helper.

Snapshot demo media: `MediaModule.Initialize` registers everything, then `if (ctx.Settings.ReadOnly) { SeedDemo(); return; }` (Title "Midnight City", Artist "M83", playing, 1:12 of 4:03, no artwork, `IsAvailable/IsReady/HasSession/HasTimeline` true), the same pattern Clipboard uses. `Snapshot` drops its `AppState` parameter and `pill-media.png`; `pill.png` now shows the demo track and glance.

### Game mode and Edit mode become shell features

```
Modules/GameMode/GameClassifier.cs   -> Shell/GameMode/GameClassifier.cs     (namespace QNotch.Shell.GameMode)
Modules/GameMode/GameModeNative.cs   -> Shell/GameMode/GameModeNative.cs
Modules/GameMode/GameModeSection.cs  -> Shell/GameMode/GameModeSection.cs
Modules/GameMode/GameModeSettings.cs -> Shell/GameMode/GameModeSettings.cs  (+ GameModeOverride enum)
Modules/GameMode/GameModeModule.cs   -> Shell/GameMode/GameModeController.cs (internal sealed class, not an INotchModule)
Modules/GameMode/GameBar.xaml(.cs)   -> deleted (EnsureBar builds the strip from segments)
Modules/EditMode/EditModeModule.cs   -> Shell/EditMode.cs (internal sealed class EditModeController)
```

`GameModeController`:

```csharp
internal GameModeController(ShellController shell, SettingsStore store, ForegroundWatcher foreground, Registry<SegmentDescriptor> segments);
public GameModeOverride Override { get; set; }          // runtime only, starts Auto
public event Action<GameModeOverride>? OverrideChanged;
public void CycleOverride();                            // hotkey
public bool IsActive { get; }  public string Reason { get; }  public event Action? StatusChanged;
public void Start();                                    // ApplicationIdle: load gamemode.json (+ migrate), self-test, hooks, first Request
internal GameModeSettings Settings { get; }
internal void SettingsChanged(bool redetect = false);   // save, ApplyLayout, re-apply toggles, optional Request
internal bool IsSegmentOn(string id);                   // Settings.Segments.TryGetValue(id, out v) ? v : true
internal void SetSegment(string id, bool on);
void EnsureBar();                                       // see Segments
```

- Constructor is cheap (no file read, no hooks): `ShellController`'s constructor creates it as `GameMode`. `App` calls `shell.GameMode.Start()` in the same ApplicationIdle callback as the late modules (first thing), and eagerly in snapshot mode. Cold path unchanged: gamemode.json is still read after the first frame.
- `Apply(active)` calls `EnsureBar()` then `shell.SetGameBarActive(active)`. The `OnDataChanged` / `RefreshSegments` logic disappears (segments own data visibility).
- Settings (`gamemode.json`, same file): replace `ShowMedia..ShowClock` with `public Dictionary<string, bool> Segments { get; set; } = new();` (missing = on). Keep the seven old names as `[JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public bool? ShowX { get; set; }`; `Start()` folds any non-null value into `Segments` (`ShowMedia`->`media.game`, `ShowCpu`->`stats.game.cpu`, `ShowGpu`->`stats.game.gpu`, `ShowRam`->`stats.game.ram`, `ShowNet`->`stats.game.net`, `ShowBattery`->`stats.game.battery`, `ShowClock`->`stats.game.clock`), nulls them and saves once.
- `GameModeSection.Create(GameModeController game, GeneralSettings gs, Registry<SegmentDescriptor> segments)`: same page; the Segments group lists `segments.Items.Where(s => s.Slot == SegmentSlot.GameBar)` with `UiKit.Row(s.Title, s.Hint, UiKit.Toggle(game.IsSegmentOn(s.Id), v => game.SetSegment(s.Id, v)))`. The Muted note becomes "Segments without data stay hidden. A frame rate slot is reserved for a later version." Registered by `App.Boot` next to general/appearance (`"gamemode", "Game mode", Glyphs.Game, 20`).
- `TrayIcon(NotchWindow, ShellController, Action exit)` reads `shell.Mode`, `shell.GameMode.Override`, subscribes `shell.ModeChanged` and `shell.GameMode.OverrideChanged`.
- `ShellController.RegisterHotkeys`: the game hotkey calls `GameMode.CycleOverride()`.
- `EditModeController(ShellController shell, CardLayout layout)` is created in the `ShellController` constructor (two event subscriptions, nothing else). Code otherwise unchanged (`_ctx.Dispatcher` -> the shell's dispatcher). `HomeView(CardLayout, ShellController)`.

### IShell after the refactor

```csharp
public interface IShell
{
    nint Hwnd { get; }
    void AddHwndHook(HwndSourceHook hook);
    void RemoveHwndHook(HwndSourceHook hook);
    string ActiveTab { get; }
    event Action<string>? TabChanged;
    void SelectTab(string tabId);
    void ClosePanel();
    bool IsPinned { get; }
    bool IsEditMode { get; }
    IDisposable HoldOpen();
    void OpenSettings(string? sectionId = null);
    event Action? FileDragEntered;
    event Action<string[]>? FilesDropped;
}
```

| Member | Fate |
| --- | --- |
| `Hwnd`, `AddHwndHook`, `RemoveHwndHook`, `ActiveTab`, `TabChanged`, `SelectTab`, `ClosePanel`, `HoldOpen`, `OpenSettings`, `FileDragEntered`, `FilesDropped` | kept (used by Clipboard, Stats, Media, Ai, FileTray, NoteGithub) |
| `IsPinned`, `IsEditMode` | kept, get only (Ai, FileTray). Setters stay on `ShellController` |
| `Mode`, `ModeChanged`, `OpenPanel`, `TogglePanel`, `RequestKeyboardFocus`, `EditModeChanged`, `Foreground`, `Monitor`, `General` | removed from IShell, stay public on `ShellController` (tray, App, HomeView, controllers) |
| `GameModeOverride`, `GameModeOverrideChanged` | moved to `GameModeController` |
| `SetGameBarActive`, `SetGameBarView`, `SetGameBarLayout` | `internal` on `ShellController`, called by `GameModeController` and `Snapshot` |
| `SetClickThrough` | removed (only `NotchWindow.SetClickThrough`, called by `SetGameBarActive`) |

`ModuleContext` keeps `Bus, Settings, Hotkeys, Shell, Dispatcher, Cards, Tabs, SettingsSections`, adds `Segments`, drops `State` and `CardLayout`.

### Resulting layout

```
Core/      EventBus, SettingsStore, GeneralSettings, Log, Motion, MemoryTrim, Autostart, Paths, UiCulture   (no module names, no State/)
Shell/     NotchWindow, ShellController (IShell, ShellMode), ShellViewModel (no State), HomeView, CardHost, CardLayout,
           SegmentHost, EditMode.cs, GameMode/, Settings/{General,Features,Appearance}Section, TrayIcon, HotkeyService,
           ForegroundWatcher, Monitors, SettingsWindow, Snapshot, AppIcon
Modules/   Contracts.cs, ModuleList.cs, Stats/, Media/, Clipboard/, Ai/, NoteGithub/, FileTray/   (each owns its state)
```

## Work split

Everything is done by the Core stage on main. The four remaining state moves (Ai, Clipboard, FileTray, NoteGithub) are a `git mv`, a namespace line and a few lines of wiring each. Four worktrees would cost more (build, launch and measure each) than the edits, and they would need a temporary AppState shim. So there are no parallel work items.

Core order (build after each step):

1. Env vars (Paths, mutex name, `--restart` wait).
2. Contracts: `SegmentSlot`, `SegmentDescriptor`, `ModuleInfo`, `ModuleContext` changes, `ModuleList.All`, `UiKit.Toggle(value, set)`, `Glyphs.Apps`.
3. State moves for all six modules; Stats and Media register their segments; Media snapshot seed.
4. Shell: pill and glance from segments, `ShellViewModel` without State, IShell shrink, HomeView.
5. Game mode and Edit mode under `Shell/`, game bar from segments, settings migration, tray, Snapshot.
6. Features section and restart.
7. Docs: ARCHITECTURE.md (layout, module contract, segments, IShell, state, snapshot outputs, test env vars, "you own only `Modules/<Name>/`"), README.md (Features section, env vars, data folder).

## Verification (Core and Integrate)

- `dotnet build -c Release`: 0 errors, 0 warnings.
- Boundary greps must be empty:
  `rg "QNotch\.Modules\.\w+" src/QNotch/Core src/QNotch/Shell src/QNotch/Theme src/QNotch/App.xaml.cs` (only `QNotch.Modules` contracts namespace allowed),
  `rg "StatsModule|MediaModule|StatsState|MediaState|ClipboardState|AiState|FileTrayState|NoteGithubState|AppState" src/QNotch/Core src/QNotch/Shell src/QNotch/Theme src/QNotch/App.xaml.cs`,
  `Test-Path src/QNotch/Core/State` is false.
- Snapshot (`QNOTCH_INSTANCE`/`QNOTCH_DATA_DIR` set): `pill.png`, `gamebar.png`, `gamebar-corner.png`, `tab-*.png`, `settings-features.png`, `settings-gamemode.png` look like the pre-refactor ones (take a baseline snapshot before step 1).
- Perf (published build to a private output dir, unique env vars, stop by PID): alive after 8 s, CPU time over 30 s idle within baseline (about 0.08% of one core), WorkingSet64 about 42 MB, PrivateMemorySize64 52 to 54 MB, cold start 495 to 540 ms (`Started in N ms` log line), no `crash.log`.
- Disable flow: a data dir whose `general.json` has `"DisabledModules": ["clipboard","ai","notegithub","filetray"]` starts, logs them as off, and idles at or below the baseline. Restart flow: start A, start B with `--restart`, stop A: B takes over within a second.
- Game mode migration: a `gamemode.json` with `"ShowGpu": false` becomes `"Segments": {"stats.game.gpu": false}` after start.
