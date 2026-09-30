using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Theme;
using MediaState = QNotch.Core.MediaState;

namespace QNotch.Shell;

/// <summary>
/// Owns the shell state machine (Collapsed / Expanded / GameBar), hover timing, hotkeys, cadence and settings reactions.
/// The window is a dumb view; providers never see any of this except through <see cref="IShell"/>.
/// </summary>
public sealed class ShellController : IShell
{
    readonly NotchWindow _w;
    readonly AppState _state;
    readonly SettingsStore _store;
    readonly Registry<TabDescriptor> _tabs;
    readonly Registry<SettingsSectionDescriptor> _sections;
    readonly Dictionary<string, FrameworkElement> _tabViews = new();
    readonly Dictionary<string, RadioButton> _tabButtons = new();
    DispatcherTimer? _dwell, _leave;
    ICadenceAware[] _cadenceAware = [];
    ShellMode _mode;
    GameModeOverride _override;
    bool _hovering, _built, _wasExpandedBeforeGame;
    string _toggleKey = "", _gameKey = "";

    public ShellController(NotchWindow window, AppState state, GeneralSettings settings, SettingsStore store, HotkeyService hotkeys,
        ForegroundWatcher foreground, CardLayout layout, Registry<TabDescriptor> tabs, Registry<SettingsSectionDescriptor> sections)
    {
        _w = window; _state = state; General = settings; _store = store; Hotkeys = hotkeys; Foreground = foreground;
        Layout = layout; _tabs = tabs; _sections = sections;
        Vm = new ShellViewModel(state, settings, () => OpenSettings());
        _w.DataContext = Vm;
    }

    public ShellViewModel Vm { get; }
    public HotkeyService Hotkeys { get; }
    public CardLayout Layout { get; }
    public GeneralSettings General { get; }
    public ForegroundWatcher Foreground { get; }
    public nint Hwnd => _w.Hwnd;
    public ShellMode Mode => _mode;
    public event Action<ShellMode>? ModeChanged;
    public event Action<GameModeOverride>? GameModeOverrideChanged;
    public event Action? EditModeChanged;

    public GameModeOverride GameModeOverride
    {
        get => _override;
        set { if (_override == value) return; _override = value; GameModeOverrideChanged?.Invoke(value); }
    }

    public bool IsPinned { get => General.Pinned; set => General.Pinned = value; }
    public bool IsEditMode { get => Vm.IsEditMode; set => Vm.IsEditMode = value && Motion.Enabled && _mode == ShellMode.Expanded; }

    // ---------- startup ----------

    public void Start()
    {
        _w.InitPill();
        _w.SetMonitor(General.MonitorIndex);
        LoadProfile();
        Vm.MotionEnabled = Motion.Enabled;

        _w.HoverEntered += OnHoverEnter;
        _w.HoverLeft += OnHoverLeave;
        _w.EscPressed += ClosePanel;
        _w.KeyboardFocusLost += () => { if (_mode == ShellMode.Expanded && !_hovering && !General.Pinned) StartLeave(); };

        General.PropertyChanged += OnSetting;
        Layout.Changed += () => _store.Save("general", General);
        Vm.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ShellViewModel.IsEditMode)) EditModeChanged?.Invoke(); };
        Motion.Changed += () => { Vm.MotionEnabled = Motion.Enabled; if (!Motion.Enabled) IsEditMode = false; };
        _state.Media.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(MediaState.HasSession) or nameof(MediaState.Title) or nameof(MediaState.Artist)) _w.InvalidatePill();
            if (e.PropertyName is nameof(MediaState.HasSession) or nameof(MediaState.IsPlaying)) UpdateGlance();
        };
        _state.Stats.PropertyChanged += (_, e) =>
        {
            var n = e.PropertyName ?? "";
            if (n.EndsWith("Text") || n is nameof(StatsState.Clock) or nameof(StatsState.HasBattery) or nameof(StatsState.BatteryGlyph)) _w.InvalidatePill();
        };
        Foreground.Changed += h => { if (h != _w.Hwnd) _w.ReassertTopmost(); };
        _w.Source.AddHook(SettingsHook);

        RegisterHotkeys();
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            EnsurePanelBuilt();
            if (General.Pinned) OpenPanel();
            MemoryTrim.Schedule(4000);
        });
    }

    public void SetCadenceAware(IEnumerable<ICadenceAware> modules)
    {
        _cadenceAware = modules.ToArray();
        NotifyCadence();
    }

    void NotifyCadence()
    {
        var c = _mode == ShellMode.Expanded ? Cadence.Fast : Cadence.Slow;
        foreach (var m in _cadenceAware)
        {
            try { m.SetCadence(c); } catch (Exception ex) { Log.Error($"SetCadence failed in {m.GetType().Name}", ex); }
        }
    }

    void SetMode(ShellMode m)
    {
        if (_mode == m) return;
        _mode = m;
        UpdateGlance();
        ModeChanged?.Invoke(m);
        NotifyCadence();
    }

    void UpdateGlance() => Vm.ShowGlance = _mode == ShellMode.Collapsed && _state.Media.HasSession && _state.Media.IsPlaying;

    // ---------- panel open / close ----------

    public void OpenPanel()
    {
        if (_mode != ShellMode.Collapsed) return;
        EnsurePanelBuilt();
        StopTimers();
        SetMode(ShellMode.Expanded);
        _w.SetOpen(true);
    }

    public void ClosePanel()
    {
        if (_mode != ShellMode.Expanded) return;
        StopTimers();
        IsEditMode = false;
        _w.DisableKeyboard();
        SetMode(ShellMode.Collapsed);
        _w.SetOpen(false);
        MemoryTrim.Schedule();
    }

    public void TogglePanel()
    {
        if (_mode == ShellMode.Expanded) ClosePanel();
        else OpenPanel();
    }

    public void RequestKeyboardFocus() => _w.EnableKeyboard();

    public void OpenSettings(string? sectionId = null) => SettingsWindow.Show(_sections, General, sectionId);

    // ---------- hover ----------

    void OnHoverEnter()
    {
        _hovering = true;
        _leave?.Stop();
        if (_mode == ShellMode.Collapsed) Start(ref _dwell, General.HoverDwellMs, OpenPanel);
    }

    void OnHoverLeave()
    {
        _hovering = false;
        _dwell?.Stop();
        if (_mode == ShellMode.Expanded && !General.Pinned && !_w.HasKeyboard) StartLeave();
    }

    void StartLeave() => Start(ref _leave, General.LeaveDelayMs, () =>
    {
        if (!_hovering && !General.Pinned && !_w.HasKeyboard) ClosePanel();
    });

    void Start(ref DispatcherTimer? t, int ms, Action action)
    {
        if (t is null)
        {
            var timer = new DispatcherTimer(DispatcherPriority.Input);
            timer.Tick += (_, _) => { timer.Stop(); ((Action)timer.Tag!)(); };
            t = timer;
        }
        t.Stop();
        t.Interval = TimeSpan.FromMilliseconds(Math.Max(1, ms));
        t.Tag = action;
        t.Start();
    }

    void StopTimers() { _dwell?.Stop(); _leave?.Stop(); }

    // ---------- game bar plumbing ----------

    public void SetGameBarActive(bool active)
    {
        if (active == (_mode == ShellMode.GameBar)) return;
        if (active)
        {
            _wasExpandedBeforeGame = _mode == ShellMode.Expanded;
            StopTimers();
            IsEditMode = false;
            _w.DisableKeyboard();
            _w.EnterGameBar();
            _w.SetClickThrough(true);
            SetMode(ShellMode.GameBar);
        }
        else
        {
            _w.SetClickThrough(false);
            _w.ExitGameBar();
            SetMode(ShellMode.Collapsed);
            if (_wasExpandedBeforeGame && General.Pinned) OpenPanel();
        }
    }

    public void SetGameBarView(UIElement? view) => _w.SetGameBarView(view);
    public void SetClickThrough(bool on) => _w.SetClickThrough(on);
    public void SetGameBarLayout(double height, double opacity, double offsetX, double offsetY) => _w.SetGameBarLayout(height, opacity, offsetX, offsetY);
    public void AddHwndHook(HwndSourceHook hook) => _w.Source.AddHook(hook);

    // ---------- tabs ----------

    void EnsurePanelBuilt()
    {
        if (_built) return;
        _built = true;
        var strip = _w.TabStrip;
        foreach (var t in _tabs.Items)
        {
            var id = t.Id;
            var rb = new RadioButton { Style = (Style)Application.Current.FindResource("TabButton"), Content = t.Glyph, ToolTip = t.Title, GroupName = "tabs" };
            rb.Checked += (_, _) => SelectTab(id);
            if (strip.Children.Count > 0) rb.Margin = new Thickness(2, 0, 0, 0);
            strip.Children.Add(rb);
            _tabButtons[id] = rb;
        }
        var start = _tabs.Find(General.LastTab) is not null ? General.LastTab : "home";
        SelectTab(start);
        _w.WarmUpPanel();
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, PrebuildNext);
    }

    void PrebuildNext()
    {
        var next = _tabs.Items.FirstOrDefault(t => !_tabViews.ContainsKey(t.Id));
        if (next is null) return;
        EnsureView(next);
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, PrebuildNext);
    }

    FrameworkElement EnsureView(TabDescriptor t)
    {
        if (_tabViews.TryGetValue(t.Id, out var v)) return v;
        try { v = t.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Tab '{t.Id}' failed to build", ex);
            v = Placeholder.Create(Glyphs.Warning, t.Title, "This tab failed to load. See logs.");
        }
        v.Visibility = Visibility.Collapsed;
        _tabViews[t.Id] = v;
        _w.TabHost.Children.Add(v);
        return v;
    }

    public void SelectTab(string id)
    {
        var t = _tabs.Find(id);
        if (t is null) return;
        var view = EnsureView(t);
        foreach (var (k, el) in _tabViews) el.Visibility = k == id ? Visibility.Visible : Visibility.Collapsed;
        if (_tabButtons.TryGetValue(id, out var rb) && rb.IsChecked != true) rb.IsChecked = true;
        Vm.IsHomeSelected = id == "home";
        if (id != "home") IsEditMode = false;
        General.LastTab = id;
    }

    // ---------- settings reactions ----------

    void OnSetting(object? s, PropertyChangedEventArgs e)
    {
        _store.Save("general", General);
        switch (e.PropertyName)
        {
            case nameof(GeneralSettings.MonitorIndex): _w.SetMonitor(General.MonitorIndex); break;
            case nameof(GeneralSettings.AccentColor) or nameof(GeneralSettings.Theme): ThemeManager.Apply(General); break;
            case nameof(GeneralSettings.ReduceMotion): Motion.Refresh(General.ReduceMotion); break;
            case nameof(GeneralSettings.ProfileName) or nameof(GeneralSettings.ProfileImagePath): LoadProfile(); break;
            case nameof(GeneralSettings.StartWithWindows): Autostart.Set(General.StartWithWindows); break;
            case nameof(GeneralSettings.ToggleHotkey) or nameof(GeneralSettings.GameModeHotkey): RegisterHotkeys(); break;
            case nameof(GeneralSettings.Pinned):
                if (General.Pinned) _leave?.Stop();
                else if (_mode == ShellMode.Expanded && !_hovering) StartLeave();
                break;
        }
    }

    void RegisterHotkeys()
    {
        Hotkeys.Unregister(_toggleKey);
        Hotkeys.Unregister(_gameKey);
        _toggleKey = General.ToggleHotkey;
        _gameKey = General.GameModeHotkey;
        Hotkeys.Register(_toggleKey, () => { if (_mode != ShellMode.GameBar) TogglePanel(); });
        Hotkeys.Register(_gameKey, () => GameModeOverride = (GameModeOverride)(((int)_override + 1) % 3));
    }

    nint SettingsHook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == Native.WM_SETTINGCHANGE)
        {
            Motion.Refresh(General.ReduceMotion);
            if (General.Theme == ThemeChoice.System && lParam != 0 &&
                System.Runtime.InteropServices.Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet") ThemeManager.Apply(General);
        }
        return 0;
    }

    void LoadProfile()
    {
        var name = General.ProfileName?.Trim() ?? "";
        Vm.ProfileInitial = name.Length > 0 ? name[..1].ToUpperInvariant() : "?";
        Vm.ProfileImage = null;
        var p = General.ProfileImagePath;
        if (string.IsNullOrEmpty(p) || !File.Exists(p)) return;
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource = new Uri(p);
            bmp.DecodePixelWidth = 96;
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.EndInit();
            bmp.Freeze();
            Vm.ProfileImage = bmp;
        }
        catch (Exception ex) { Log.Warn("Profile image unreadable", ex); }
    }
}
