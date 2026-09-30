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
        _mutex = new Mutex(true, @"Local\QNotch.SingleInstance", out var first);
        if (!first) { Shutdown(); return; }
        try { Boot(); }
        catch (Exception ex)
        {
            Log.Crash("Startup", ex);
            Shutdown(1);
        }
    }

    void Boot()
    {
        _store = new SettingsStore();
        var gs = _store.Get<GeneralSettings>("general");
        Motion.Refresh(gs.ReduceMotion);
        ThemeManager.Apply(gs);

        var bus = new EventBus(Dispatcher);
        var state = new AppState();
        var cards = new Registry<CardDescriptor>();
        var tabs = new Registry<TabDescriptor>();
        var sections = new Registry<SettingsSectionDescriptor>();

        var window = new NotchWindow();
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
        _tray = new TrayIcon(window, shell, () => Shutdown());

        // Any text input in the panel activates the window on mouse down so typing works despite WS_EX_NOACTIVATE.
        var handler = new MouseButtonEventHandler(OnTextMouseDown);
        EventManager.RegisterClassHandler(typeof(TextBoxBase), UIElement.PreviewMouseDownEvent, handler);
        EventManager.RegisterClassHandler(typeof(PasswordBox), UIElement.PreviewMouseDownEvent, handler);
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
