using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Core.Updates;
using QNotch.Modules;
using QNotch.Shell;
using QNotch.Shell.Diagnostics;
using QNotch.Shell.GameMode;
using QNotch.Shell.Settings;
using QNotch.Theme;

namespace QNotch;

public partial class App : Application
{
    // Cold start: the UI thread spends ~200 ms in first-use costs (font cache, text stack, control type loads). A pool thread pays
    // them in parallel. Nothing here touches a DispatcherObject.
    static App()
    {
        // English UI text: numbers ("20.8/31.9 GB") and dates must not come out in the OS language either.
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = UiCulture.Value;
        System.Globalization.CultureInfo.CurrentCulture = UiCulture.Value;
        Warm();
    }

    static void Warm() => Task.Run(() =>
    {
        try
        {
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            foreach (var (family, text) in new[] { ("Segoe UI Variable Text, Segoe UI", "CPU 12% RAM 4.2/15.7 GB 09:41"), ("Segoe Fluent Icons, Segoe MDL2 Assets", "") })
            {
                var tf = new System.Windows.Media.Typeface(new System.Windows.Media.FontFamily(family), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
                _ = new System.Windows.Media.FormattedText(text, inv, FlowDirection.LeftToRight, tf, 12, null!, 1.0).Width;
            }
            foreach (var t in new[] { typeof(Window), typeof(Button), typeof(ToggleButton), typeof(TextBox), typeof(ComboBox), typeof(Slider), typeof(ScrollViewer), typeof(Border), typeof(Grid), typeof(StackPanel), typeof(TextBlock), typeof(Image) })
                System.Runtime.CompilerServices.RuntimeHelpers.RunClassConstructor(t.TypeHandle);
            _ = System.Text.Json.JsonSerializer.Deserialize<GeneralSettings>("{}", SettingsStore.Json);
        }
        catch { /* warm-up only */ }
    });

    Mutex? _mutex;
    HotkeyService? _hotkeys;
    ForegroundWatcher? _foreground;
    TrayIcon? _tray;
    SettingsStore? _store;
    ShellController? _shell;
    UpdateService? _updates;
    // --debug-control: the debug channel (Shell/Diagnostics/DebugChannel.cs) opens once the shell and every module are up.
    bool _debugControl;
    IDisposable? _debug;
    readonly HashSet<string> _running = new(StringComparer.OrdinalIgnoreCase);
    readonly List<IDisposable> _moduleResources = new();

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Log.InstallHandlers(this);
        // Layered (per-pixel alpha) windows read the whole surface back from the GPU every frame; software rendering is as fast
        // for this UI (same frame rate measured) and saves about 20 MB of commit (no D3D device).
        System.Windows.Media.RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        // Dev tool: QNotch.exe --snapshot <dir> [--appearance light|dark] renders every view to PNG and exits (see Shell/Snapshot.cs).
        var diag = DiagnosticOptions.Parse(e.Args);
        // --smoke-test and --measure boot the same way (read-only, no mutex, demo data) and hand over to Shell/Diagnostics/DiagnosticRun.cs.
        var snapDir = diag.RunsOnce ? diag.Dir : null;
        _debugControl = diag.Mode == DiagnosticMode.DebugControl;
        if (snapDir is null)
        {
            // QNOTCH_INSTANCE keeps parallel test runs apart. --restart: the previous instance is shutting down, wait for its mutex.
            var m = new Mutex(true, @"Local\QNotch.SingleInstance" + (Environment.GetEnvironmentVariable("QNOTCH_INSTANCE") is { Length: > 0 } i ? "." + i : ""), out var first);
            if (!first)
            {
                var ok = false;
                if (e.Args.Contains("--restart"))
                {
                    try { ok = m.WaitOne(10_000); }
                    catch (AbandonedMutexException) { ok = true; }
                }
                if (!ok) { m.Dispose(); Shutdown(); return; }
            }
            _mutex = m;
        }
        try { Boot(snapDir, diag); }
        catch (Exception ex)
        {
            Log.Crash("Startup", ex);
            Shutdown(1);
        }
    }
    void Boot(string? snapDir, DiagnosticOptions diag)
    {
        _store = new SettingsStore { ReadOnly = snapDir is not null };
        var fresh = !_store.Exists("general");
        var gs = _store.Get<GeneralSettings>("general");
        // --measure loads like a normal start (early modules first, the rest and Game mode at idle); snapshot and smoke load everything at once.
        var measure = diag.Mode == DiagnosticMode.Measure;
        if (snapDir is not null) // snapshots load every module, follow the system appearance unless told otherwise and show a demo profile
        {
            gs.Pinned = false; gs.DisabledModules = DiagnosticRun.BootDisabled(diag); gs.ProfileName = "Alex"; gs.ProfileImagePath = "";
            gs.LocalEnabledModules = ModuleList.All.Where(i => !i.DefaultEnabled && !gs.DisabledModules.Contains(i.Id)).Select(i => i.Id).ToList();
            gs.Theme = diag.Appearance switch { "light" => ThemeChoice.Light, "dark" => ThemeChoice.Dark, _ => ThemeChoice.System };
        }
        // Welcome tour: only on a fresh install. Settings from before it existed record it as done, silently.
        var tour = FirstRun.Decide(!fresh, gs.OnboardingDone, snapDir is not null);
        if (tour == TourStart.MarkDone) { gs.OnboardingDone = true; _store.Save("general", gs); }
        Motion.Refresh(gs.ReduceMotion);
        ThemeManager.Apply(gs);
        var bus = new EventBus(Dispatcher);
        var cards = new Registry<CardDescriptor>();
        var tabs = new Registry<TabDescriptor>();
        var sections = new Registry<SettingsSectionDescriptor>();
        var segments = new Registry<SegmentDescriptor>();
        var demos = new Registry<DemoState>();
        var quickActions = new Registry<QuickActionDescriptor>();

        var window = new NotchWindow { Offscreen = snapDir is not null };
        window.InitHandle();
        _hotkeys = new HotkeyService(window.Source);
        _foreground = new ForegroundWatcher();
        _foreground.Start();
        var layout = new CardLayout(cards, gs);
        var shortcuts = new Shortcuts(_hotkeys, _store);
        var sounds = new Sounds(_store);
        _shell = new ShellController(window, gs, _store, shortcuts, _foreground, layout, tabs, sections, segments, quickActions);
        var shell = _shell;
        shell.AddShortcuts();
        // Before any module and the update service: the feature choices apply now, and a completed or skipped tour has made the update choice.
        // A --debug-control run never opens the tour by itself (spec/diagnostics.md); the onboarding command does.
        var openAfterTour = tour == TourStart.Show && !_debugControl && RunTour(gs, _store, shortcuts);
        _updates = new UpdateService(gs, Dispatcher, _store, () => Shutdown());
        var updates = _updates;
        segments.Register(new SegmentDescriptor("updates.pill", SegmentSlot.PillRight, 2,
            () => UpdatesSection.Indicator(updates, () => shell.OpenSettings("updates"))));

        // Modules the user turned off are never created. A change in Settings, Features applies on the next start.
        foreach (var (old, ids) in ModuleList.Renamed)
            if (gs.DisabledModules.RemoveAll(x => string.Equals(x, old, StringComparison.OrdinalIgnoreCase)) > 0) gs.DisabledModules.AddRange(ids);
        var bootDisabled = (snapDir is not null ? DiagnosticRun.BootDisabled(diag) : ModuleList.All.Where(i => !i.IsEnabled(gs)).Select(i => i.Id))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var enabled = ModuleList.All.Where(i => !bootDisabled.Contains(i.Id)).ToList();
        Log.Info($"Modules: {string.Join(", ", enabled.Select(i => i.Id))} (off: {(bootDisabled.Count == 0 ? "none" : string.Join(", ", bootDisabled))})");

        // Built-in tab and settings sections (modules add theirs in Initialize).
        tabs.Register(new TabDescriptor("home", "Home", Glyphs.Home, 0, () => new HomeView(layout, shell)));
        sections.Register(new SettingsSectionDescriptor("features", "Features", Glyphs.Apps, 5, () => FeaturesSection.Create(gs, _store!, ModuleList.All, bootDisabled, Restart, layout, tabs, segments)));
        sections.Register(new SettingsSectionDescriptor("general", "General", Glyphs.Settings, 0, () => GeneralSection.Create(gs, _store!, SetupCode.All(ModuleList.All), Restart, shell.Nudge.ResetAll,
            () => ShowTour(gs, _store!, shortcuts, shell))));
        sections.Register(new SettingsSectionDescriptor("updates", "Updates", UpdatesSection.UpdateGlyph, 6, () => UpdatesSection.Create(gs, updates)));
        sections.Register(new SettingsSectionDescriptor("appearance", "Appearance", Glyphs.Color, 10, () => AppearanceSection.Create(gs, layout)));
        sections.Register(new SettingsSectionDescriptor("hotkeys", "Hotkeys", "", 7, () => HotkeysSection.Create(shortcuts)));
        sections.Register(new SettingsSectionDescriptor("sounds", "Sounds", Glyphs.Volume, 8, () => SoundsSection.Create(sounds)));
        sections.Register(new SettingsSectionDescriptor("gamemode", "Game mode", Glyphs.Game, 20, () => GameModeSection.Create(shell.GameMode, shortcuts, segments)));

        var ctx = new ModuleContext
        {
            Bus = bus, Settings = _store, Hotkeys = _hotkeys, Shell = shell, Dispatcher = Dispatcher,
            Cards = cards, Tabs = tabs, SettingsSections = sections, Segments = segments, Search = new(), Shortcuts = shortcuts, Sounds = sounds, Demos = demos, QuickActions = quickActions,
        };
        var built = new List<(string Id, INotchModule Module)>();
        List<INotchModule> Init(IEnumerable<ModuleInfo> list)
        {
            var done = new List<INotchModule>();
            foreach (var info in list)
            {
                INotchModule m;
                try { m = info.Create(); }
                catch (Exception ex) { Log.Error($"Module '{info.Id}' failed to create", ex); continue; }
                done.Add(m);
                built.Add((info.Id, m));
                if (m is IDisposable resource) _moduleResources.Add(resource);
                cards.RegistrationOwner = tabs.RegistrationOwner = segments.RegistrationOwner = info.Id;
                try { m.Initialize(ctx); _running.Add(info.Id); }
                catch (Exception ex) { Log.Error($"Module '{info.Id}' failed to initialize", ex); }
                finally { cards.RegistrationOwner = tabs.RegistrationOwner = segments.RegistrationOwner = ""; }
            }
            return done;
        }
        // Cold start: the pill needs only the Early modules (they register pill and glance segments). The rest, and Game mode, start right
        // after the first frame. Queued before shell.Start so late modules register their tabs and cards before the panel is first built.
        var early = Init(enabled.Where(i => i.Early || (snapDir is not null && !measure)));
        if (snapDir is null || measure)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () =>
            {
                shell.GameMode.Start();
                shell.SetCadenceAware(early.Concat(Init(enabled.Where(i => !i.Early))).OfType<ICadenceAware>());
            });
        shell.Start();
        if (snapDir is not null && !measure) shell.GameMode.Start();
        shell.SetCadenceAware(early.OfType<ICadenceAware>());
        window.Show();
        window.Reposition();

        // Any text input in the panel activates the window on mouse down so typing works despite WS_EX_NOACTIVATE.
        var handler = new MouseButtonEventHandler(OnTextMouseDown);
        EventManager.RegisterClassHandler(typeof(TextBoxBase), UIElement.PreviewMouseDownEvent, handler);
        EventManager.RegisterClassHandler(typeof(PasswordBox), UIElement.PreviewMouseDownEvent, handler);

        if (snapDir is not null)
        {
            var scene = new SnapshotScene(window, shell, tabs, sections, layout, demos, save => SnapshotTour(gs, _store, shortcuts, save));
            if (diag.Mode == DiagnosticMode.Snapshot) Snapshot.Run(scene, diag, Shutdown);
            else DiagnosticRun.Start(diag, new DiagnosticHost(scene, gs, _store, shortcuts, layout, cards, sections, segments, ctx.Search, built,
                pipe => DebugChannel.Start(new DebugHost(window, shell, shortcuts, tabs, sections, bootDisabled, _running, () => ShowTour(gs, _store!, shortcuts, shell), () => { }), pipe)), Shutdown);
            return;
        }
        _tray = new TrayIcon(window, shell, shortcuts, () => Shutdown(), updates);
        updates.Start();
        if (updates.State.NeedsPreferenceChoice)
        {
            var promptPending = true;
            void PromptUpdateChoice(ShellMode mode)
            {
                if (!promptPending || mode == ShellMode.GameBar) return;
                promptPending = false;
                shell.ModeChanged -= PromptUpdateChoice;
                if (updates.State.NeedsPreferenceChoice) shell.OpenSettings("updates");
            }
            shell.ModeChanged += PromptUpdateChoice;
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () => PromptUpdateChoice(shell.Mode));
        }
        // Open QNotch: the panel on Home with the keyboard, once the late modules registered their cards (queued after them).
        if (openAfterTour)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () => shell.OpenPanelWithKeyboard("home"));
        if (_debugControl)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () => StartDebug(window, shell, shortcuts, tabs, sections, bootDisabled, gs));
        Log.Info($"Started in {(DateTime.Now - System.Diagnostics.Process.GetCurrentProcess().StartTime).TotalMilliseconds:0} ms");
    }

    // The tour lives in its own methods (never inlined into Boot), so a normal start does not load its types.

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    static bool RunTour(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts)
    {
        var open = Shell.Onboarding.Tour.RunFirst(gs, store, shortcuts, ModuleList.All);
        if (gs.StartWithWindows) Autostart.Set(true); // the shell's settings reaction is not wired up yet
        return open;
    }

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    static void ShowTour(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts, ShellController shell) =>
        Shell.Onboarding.Tour.ShowOnDemand(gs, store, shortcuts, ModuleList.All, id => shell.OpenSettings(id), () => shell.OpenPanelWithKeyboard("home"));

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    static void SnapshotTour(GeneralSettings gs, SettingsStore store, Shortcuts shortcuts, Action<FrameworkElement, string> save) =>
        Shell.Onboarding.Tour.Snapshot(gs, store, shortcuts, ModuleList.All, save);

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    void StartDebug(NotchWindow window, ShellController shell, Shortcuts shortcuts, Registry<TabDescriptor> tabs, Registry<SettingsSectionDescriptor> sections,
        HashSet<string> bootDisabled, GeneralSettings gs)
    {
        try { _debug = DebugChannel.Start(new DebugHost(window, shell, shortcuts, tabs, sections, bootDisabled, _running, () => ShowTour(gs, _store!, shortcuts, shell), () => Shutdown())); }
        catch (Exception ex) { Log.Error("Debug channel failed to start", ex); }
    }

    /// <summary>Starts a fresh instance (it waits for our mutex, released last in OnExit) and quits.</summary>
    public static void Restart()
    {
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!, "--restart") { UseShellExecute = false });
        Current.Shutdown();
    }

    void OnTextMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not DependencyObject d || Window.GetWindow(d) is not NotchWindow) return;
        _shell?.RequestKeyboardFocus();
        Dispatcher.BeginInvoke(() => Keyboard.Focus((IInputElement)sender));
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try
        {
            _debug?.Dispose();
            foreach (var resource in _moduleResources)
                try { resource.Dispose(); } catch (Exception ex) { Log.Warn("Module cleanup failed", ex); }
            _updates?.Dispose();
            _tray?.Dispose();
            _hotkeys?.UnregisterAll();
            _foreground?.Dispose();
            _store?.Flush();
            _mutex?.ReleaseMutex();
        }
        catch (Exception ex) { Log.Warn("Exit cleanup failed", ex); }
        base.OnExit(e);
    }
}
