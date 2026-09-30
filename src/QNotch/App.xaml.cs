using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell;
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
        if (snapDir is not null) { gs.Pinned = false; if (light) gs.Theme = ThemeChoice.Light; }
        Motion.Refresh(gs.ReduceMotion);
        ThemeManager.Apply(gs);
        var bus = new EventBus(Dispatcher);
        var state = new AppState();
        var cards = new Registry<CardDescriptor>();
        var tabs = new Registry<TabDescriptor>();
        var sections = new Registry<SettingsSectionDescriptor>();

        var window = new NotchWindow { Offscreen = snapDir is not null };
        window.InitHandle();
        _hotkeys = new HotkeyService(window.Source);
        _foreground = new ForegroundWatcher();
        _foreground.Start();
        var layout = new CardLayout(cards, gs);
        _shell = new ShellController(window, state, gs, _store, _hotkeys, _foreground, layout, tabs, sections);
        var shell = _shell;

        // Built-in tab and settings sections (modules add theirs in Initialize).
        tabs.Register(new TabDescriptor("home", "Home", Glyphs.Home, 0, () => new HomeView(layout, shell)));
        sections.Register(new SettingsSectionDescriptor("general", "General", Glyphs.Settings, 0, () => GeneralSection.Create(gs)));
        sections.Register(new SettingsSectionDescriptor("appearance", "Appearance", Glyphs.Color, 10, () => AppearanceSection.Create(gs, layout)));

        var ctx = new ModuleContext
        {
            State = state, Bus = bus, Settings = _store, Hotkeys = _hotkeys, Shell = shell, Dispatcher = Dispatcher,
            Cards = cards, Tabs = tabs, SettingsSections = sections, CardLayout = layout,
        };
        // Cold start: the pill needs only Stats (clock, numbers) and Media (glance strip). The other modules initialize right after the
        // first frame. Queued before shell.Start so they register their tabs and cards before the panel is first built.
        var modules = ModuleList.Create().ToList();
        var early = snapDir is not null ? modules : modules.Where(m => m is Modules.Stats.StatsModule or Modules.Media.MediaModule).ToList();
        void Init(IEnumerable<INotchModule> list)
        {
            foreach (var m in list)
            {
                try { m.Initialize(ctx); }
                catch (Exception ex) { Log.Error($"Module '{m.Id}' failed to initialize", ex); }
            }
        }
        Init(early);
        if (early.Count < modules.Count)
            Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, () =>
            {
                Init(modules.Except(early));
                shell.SetCadenceAware(modules.OfType<ICadenceAware>());
            });
        shell.Start();
        shell.SetCadenceAware(early.OfType<ICadenceAware>());
        window.Show();
        window.Reposition();

        // Any text input in the panel activates the window on mouse down so typing works despite WS_EX_NOACTIVATE.
        var handler = new MouseButtonEventHandler(OnTextMouseDown);
        EventManager.RegisterClassHandler(typeof(TextBoxBase), UIElement.PreviewMouseDownEvent, handler);
        EventManager.RegisterClassHandler(typeof(PasswordBox), UIElement.PreviewMouseDownEvent, handler);

        if (snapDir is not null) { Snapshot.Run(snapDir, window, shell, tabs, sections, state, () => Shutdown()); return; }
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
