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
            var m = new Mutex(true, @"Local\QNotch.SingleInstance", out var first);
            if (!first) { m.Dispose(); Shutdown(); return; }
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
        var modules = ModuleList.Create().ToList();
        foreach (var m in modules)
        {
            try { m.Initialize(ctx); }
            catch (Exception ex) { Log.Error($"Module '{m.Id}' failed to initialize", ex); }
        }

        shell.Start();
        shell.SetCadenceAware(modules.OfType<ICadenceAware>());
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
