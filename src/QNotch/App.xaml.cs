using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell;
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

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Log.InstallHandlers(this);
        // Layered (per-pixel alpha) windows read the whole surface back from the GPU every frame; software rendering is as fast
        // for this UI (same frame rate measured) and saves about 20 MB of commit (no D3D device).
        System.Windows.Media.RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        // Dev tool: QNotch.exe --snapshot <dir> [light]  renders every view to PNG and exits (see Shell/Snapshot.cs).
        var snap = Array.IndexOf(e.Args, "--snapshot");
        string? snapDir = snap >= 0 && snap + 1 < e.Args.Length ? Path.GetFullPath(e.Args[snap + 1]) : null;
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
        try { Boot(snapDir, e.Args.Contains("light")); }
        catch (Exception ex)
        {
            Log.Crash("Startup", ex);
            Shutdown(1);
        }
    }
    void Boot(string? snapDir, bool light)
    {
        _store = new SettingsStore { ReadOnly = snapDir is not null };
        var gs = _store.Get<GeneralSettings>("general");
        if (snapDir is not null) { gs.Pinned = false; gs.DisabledModules = new(); if (light) gs.Theme = ThemeChoice.Light; } // snapshots load every module
        Motion.Refresh(gs.ReduceMotion);
        ThemeManager.Apply(gs);
        var bus = new EventBus(Dispatcher);
        var cards = new Registry<CardDescriptor>();
        var tabs = new Registry<TabDescriptor>();
        var sections = new Registry<SettingsSectionDescriptor>();
        var segments = new Registry<SegmentDescriptor>();

        var window = new NotchWindow { Offscreen = snapDir is not null };
        window.InitHandle();
        _hotkeys = new HotkeyService(window.Source);
        _foreground = new ForegroundWatcher();
        _foreground.Start();
        var layout = new CardLayout(cards, gs);
        _shell = new ShellController(window, gs, _store, _hotkeys, _foreground, layout, tabs, sections, segments);
        var shell = _shell;

        // Modules the user turned off are never created. A change in Settings, Features applies on the next start.
        var bootDisabled = gs.DisabledModules.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var enabled = ModuleList.All.Where(i => !bootDisabled.Contains(i.Id)).ToList();
        Log.Info($"Modules: {string.Join(", ", enabled.Select(i => i.Id))} (off: {(bootDisabled.Count == 0 ? "none" : string.Join(", ", bootDisabled))})");

        // Built-in tab and settings sections (modules add theirs in Initialize).
        tabs.Register(new TabDescriptor("home", "Home", Glyphs.Home, 0, () => new HomeView(layout, shell)));
        sections.Register(new SettingsSectionDescriptor("features", "Features", Glyphs.Apps, 5, () => FeaturesSection.Create(gs, _store!, ModuleList.All, bootDisabled, Restart)));
        sections.Register(new SettingsSectionDescriptor("general", "General", Glyphs.Settings, 0, () => GeneralSection.Create(gs)));
        sections.Register(new SettingsSectionDescriptor("appearance", "Appearance", Glyphs.Color, 10, () => AppearanceSection.Create(gs, layout)));
        sections.Register(new SettingsSectionDescriptor("gamemode", "Game mode", Glyphs.Game, 20, () => GameModeSection.Create(shell.GameMode, gs, segments)));

        var ctx = new ModuleContext
        {
            Bus = bus, Settings = _store, Hotkeys = _hotkeys, Shell = shell, Dispatcher = Dispatcher,
            Cards = cards, Tabs = tabs, SettingsSections = sections, Segments = segments,
        };
        List<INotchModule> Init(IEnumerable<ModuleInfo> list)
        {
            var done = new List<INotchModule>();
            foreach (var info in list)
            {
                INotchModule m;
                try { m = info.Create(); }
                catch (Exception ex) { Log.Error($"Module '{info.Id}' failed to create", ex); continue; }
                done.Add(m);
                try { m.Initialize(ctx); }
                catch (Exception ex) { Log.Error($"Module '{info.Id}' failed to initialize", ex); }
            }
            return done;
        }
        // Cold start: the pill needs only the Early modules (they register pill and glance segments). The rest, and Game mode, start right
        // after the first frame. Queued before shell.Start so late modules register their tabs and cards before the panel is first built.
        var early = Init(enabled.Where(i => i.Early || snapDir is not null));
        if (snapDir is null)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () =>
            {
                shell.GameMode.Start();
                shell.SetCadenceAware(early.Concat(Init(enabled.Where(i => !i.Early))).OfType<ICadenceAware>());
            });
        shell.Start();
        if (snapDir is not null) shell.GameMode.Start();
        shell.SetCadenceAware(early.OfType<ICadenceAware>());
        window.Show();
        window.Reposition();

        // Any text input in the panel activates the window on mouse down so typing works despite WS_EX_NOACTIVATE.
        var handler = new MouseButtonEventHandler(OnTextMouseDown);
        EventManager.RegisterClassHandler(typeof(TextBoxBase), UIElement.PreviewMouseDownEvent, handler);
        EventManager.RegisterClassHandler(typeof(PasswordBox), UIElement.PreviewMouseDownEvent, handler);

        if (snapDir is not null) { Snapshot.Run(snapDir, window, shell, tabs, sections, () => Shutdown()); return; }
        _tray = new TrayIcon(window, shell, () => Shutdown());
        Log.Info($"Started in {(DateTime.Now - System.Diagnostics.Process.GetCurrentProcess().StartTime).TotalMilliseconds:0} ms");
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
