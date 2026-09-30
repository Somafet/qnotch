using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Modules;
using QNotch.Shell.GameMode;
using QNotch.Theme;

namespace QNotch.Shell;

public enum ShellMode { Collapsed, Expanded, GameBar }

/// <summary>
/// Owns the shell state machine (Collapsed / Expanded / GameBar), hover timing, hotkeys, cadence and settings reactions.
/// The window is a dumb view; providers never see any of this except through <see cref="IShell"/>.
/// </summary>
public sealed class ShellController : IShell
{
    readonly NotchWindow _w;
    readonly SettingsStore _store;
    readonly Registry<TabDescriptor> _tabs;
    readonly Registry<SettingsSectionDescriptor> _sections;
    readonly Registry<SegmentDescriptor> _segments;
    // Kept alive for their event subscriptions.
    readonly EditModeController _editMode;
    readonly Dictionary<string, Border> _tabViews = new();
    readonly Dictionary<string, RadioButton> _tabButtons = new();
    DispatcherTimer? _dwell, _leave;
    ICadenceAware[] _cadenceAware = [];
    ShellMode _mode;
    bool _hovering, _fileDrag, _built, _wasExpandedBeforeGame;
    int _holds;
    string _toggleKey = "", _gameKey = "", _activeTab = "home";

    public ShellController(NotchWindow window, GeneralSettings settings, SettingsStore store, HotkeyService hotkeys, ForegroundWatcher foreground,
        CardLayout layout, Registry<TabDescriptor> tabs, Registry<SettingsSectionDescriptor> sections, Registry<SegmentDescriptor> segments)
    {
        _w = window; _general = settings; _store = store; _hotkeys = hotkeys; _foreground = foreground;
        _layout = layout; _tabs = tabs; _sections = sections; _segments = segments;
        _vm = new ShellViewModel(settings, () => OpenSettings());
        _w.DataContext = _vm;
        GameMode = new GameModeController(this, store, foreground, segments);
        _editMode = new EditModeController(this, layout);
    }

    readonly ShellViewModel _vm;
    readonly HotkeyService _hotkeys;
    readonly CardLayout _layout;
    readonly GeneralSettings _general;
    readonly ForegroundWatcher _foreground;
    public nint Hwnd => _w.Hwnd;
    public nint Monitor => _w.MonitorHandle;
    public ShellMode Mode => _mode;
    public string ActiveTab => _activeTab;
    public event Action<ShellMode>? ModeChanged;
    public event Action? EditModeChanged;
    public event Action<string>? TabChanged;
    public event Action? FileDragEntered;
    public event Action<string[]>? FilesDropped;

    /// <summary>Game mode: detection, override and the game bar. Started by App after the first frame.</summary>
    internal GameModeController GameMode { get; }
    internal System.Windows.Threading.Dispatcher Dispatcher => _w.Dispatcher;

    public bool IsPinned => _general.Pinned;
    public bool IsEditMode { get => _vm.IsEditMode; set => _vm.IsEditMode = value && Motion.Enabled && _mode == ShellMode.Expanded; }

    // ---------- startup ----------

    public void Start()
    {
        BuildPill();
        BuildGlance();
        _w.PillStrip.SizeChanged += (_, _) => _w.InvalidatePill(); // content changed (segment data): re-measure once, coalesced
        _w.InitPill();
        _w.SetMonitor(_general.MonitorIndex);
        LoadProfile();
        _vm.MotionEnabled = Motion.Enabled;

        _w.HoverEntered += OnHoverEnter;
        _w.HoverLeft += OnHoverLeave;
        _w.EscPressed += ClosePanel;
        _w.KeyboardFocusLost += () => { if (!_w.IsPointerOver()) { _hovering = false; StartLeave(); } };
        _w.FileDragOver += OnFileDragOver;
        _w.DragLeft += OnHoverLeave;
        _w.FilesDropped += files =>
        {
            _fileDrag = false;
            try { FilesDropped?.Invoke(files); } catch (Exception ex) { Log.Error("FilesDropped handler failed", ex); }
        };

        _general.PropertyChanged += OnSetting;
        _layout.Changed += () => _store.Save("general", _general);
        _vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName != nameof(ShellViewModel.IsEditMode)) return;
            EditModeChanged?.Invoke();
            if (!_vm.IsEditMode && !_hovering) StartLeave();
        };
        Motion.Changed += () => { _vm.MotionEnabled = Motion.Enabled; if (!Motion.Enabled) IsEditMode = false; };
        _foreground.Changed += h => { if (h != _w.Hwnd) _w.ReassertTopmost(); };
        _w.Source.AddHook(SettingsHook);

        RegisterHotkeys();
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            EnsurePanelBuilt();
            if (_general.Pinned) OpenPanel();
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

    // ---------- pill and glance: hosted segments ----------

    /// <summary>Pill = PillLeft segments, then PillRight segments, each by Order. The shell owns the margins; a collapsed segment drops its margin, so nothing needs a wrapper.</summary>
    void BuildPill()
    {
        var strip = _w.PillStrip;
        strip.Children.Clear();
        foreach (var slot in new[] { SegmentSlot.PillLeft, SegmentSlot.PillRight })
        {
            foreach (var d in _segments.Items)
            {
                if (d.Slot != slot || SegmentHost.Build(d) is not { } el) continue;
                el.Margin = new Thickness(0, 0, slot == SegmentSlot.PillLeft ? 18 : 12, 0);
                strip.Children.Add(el);
            }
        }
        if (strip.Children.Count > 0) ((FrameworkElement)strip.Children[^1]).Margin = new Thickness(0);
    }

    /// <summary>The glance strip shows while collapsed and at least one Glance segment is visible. Hooked once per element: no polling.</summary>
    void BuildGlance()
    {
        var strip = _w.GlanceStrip;
        strip.Children.Clear();
        var vis = System.ComponentModel.DependencyPropertyDescriptor.FromProperty(UIElement.VisibilityProperty, typeof(UIElement));
        foreach (var d in _segments.Items)
        {
            if (d.Slot != SegmentSlot.Glance || SegmentHost.Build(d) is not { } el) continue;
            vis.AddValueChanged(el, (_, _) => UpdateGlance());
            strip.Children.Add(el);
        }
        UpdateGlance();
    }

    void UpdateGlance() => _vm.ShowGlance = _mode == ShellMode.Collapsed && _w.GlanceStrip.Children.OfType<UIElement>().Any(e => e.Visibility == Visibility.Visible);

    // ---------- panel open / close ----------

    public void OpenPanel()
    {
        if (_mode != ShellMode.Collapsed) return;
        EnsurePanelBuilt();
        StopTimers();
        MemoryTrim.Cancel();
        var now = DateTime.Now;
        _vm.DateText = now.ToString("dddd, MMMM d", UiCulture.Value);
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
        MemoryTrim.AfterActivity();
    }

    /// <summary>Hotkey and tray: an explicit summon also takes keyboard focus, so Esc works and a click elsewhere dismisses.</summary>
    internal void ToggleFromUser()
    {
        if (_mode == ShellMode.GameBar) return;
        if (_mode == ShellMode.Expanded) { ClosePanel(); return; }
        OpenPanel();
        _w.EnableKeyboard();
    }

    public void RequestKeyboardFocus() => _w.EnableKeyboard();

    public void OpenSettings(string? sectionId = null) => SettingsWindow.Show(_sections, _general, sectionId);

    public IDisposable HoldOpen()
    {
        _holds++;
        _leave?.Stop();
        return new Hold(this);
    }

    sealed class Hold(ShellController s) : IDisposable
    {
        bool _done;
        public void Dispose()
        {
            if (_done) return;
            _done = true;
            s._holds--;
            // WPF hover state is stale after a drag or modal dialog: ask the OS where the pointer is.
            s._hovering = s._w.IsPointerOver();
            if (!s._hovering) s.StartLeave();
        }
    }

    // ---------- hover ----------

    void OnHoverEnter()
    {
        _hovering = true;
        _leave?.Stop();
        if (_mode == ShellMode.Collapsed) Start(ref _dwell, _general.HoverDwellMs, OpenPanel);
    }

    void OnHoverLeave()
    {
        _hovering = false;
        _dwell?.Stop();
        StartLeave();
    }

    bool OnFileDragOver(bool enter)
    {
        if (FilesDropped is null || _mode == ShellMode.GameBar) return false;
        _hovering = true;
        _leave?.Stop();
        if (_mode == ShellMode.Collapsed && _dwell?.IsEnabled != true) Start(ref _dwell, _general.HoverDwellMs, OpenPanel);
        if (!_fileDrag)
        {
            _fileDrag = true;
            try { FileDragEntered?.Invoke(); } catch (Exception ex) { Log.Error("FileDragEntered handler failed", ex); }
        }
        return true;
    }

    bool CanAutoClose => _mode == ShellMode.Expanded && !_general.Pinned && !_w.HasKeyboard && _holds == 0 && !_vm.IsEditMode;

    void StartLeave()
    {
        if (!CanAutoClose) return;
        Start(ref _leave, _general.LeaveDelayMs, () =>
        {
            _fileDrag = false;
            if (!_hovering && CanAutoClose && !_w.IsPointerOver()) ClosePanel();
        });
    }

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

    internal void SetGameBarActive(bool active)
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
            if (_wasExpandedBeforeGame && _general.Pinned) OpenPanel();
        }
    }

    internal void SetGameBarView(UIElement? view) => _w.SetGameBarView(view);
    internal void SetGameBarLayout(double height, double opacity, double offsetX, double offsetY) => _w.SetGameBarLayout(height, opacity, offsetX, offsetY);
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
        SelectTab(_tabs.Find(_general.LastTab) is not null ? _general.LastTab : "home");
        _w.WarmUpPanel();
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, PrebuildNext);
    }

    /// <summary>Builds one remaining tab per idle slot; when all exist, lays the whole panel out once (inactive tabs are Hidden, so they get layout).</summary>
    void PrebuildNext()
    {
        var next = _tabs.Items.FirstOrDefault(t => !_tabViews.ContainsKey(t.Id));
        if (next is null) { if (_mode != ShellMode.Expanded) _w.WarmUpPanel(); return; }
        EnsureView(next);
        _w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, PrebuildNext);
    }

    Border EnsureView(TabDescriptor t)
    {
        if (_tabViews.TryGetValue(t.Id, out var slot)) return slot;
        FrameworkElement v;
        try { v = t.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Tab '{t.Id}' failed to build", ex);
            v = Placeholder.Create(Glyphs.Warning, t.Title, "This tab failed to load. See logs.");
        }
        // Shell-owned slot: the fade/slide transition never touches the module's own element.
        slot = new Border { Child = v, Visibility = Visibility.Hidden, RenderTransform = new TranslateTransform() };
        _tabViews[t.Id] = slot;
        _w.TabHost.Children.Add(slot);
        return slot;
    }

    public void SelectTab(string id)
    {
        var t = _tabs.Find(id);
        if (t is null) return;
        var slot = EnsureView(t);
        var changed = id != _activeTab || slot.Visibility != Visibility.Visible;
        foreach (var (k, el) in _tabViews) el.Visibility = k == id ? Visibility.Visible : Visibility.Hidden;
        if (_tabButtons.TryGetValue(id, out var rb) && rb.IsChecked != true) rb.IsChecked = true;
        var index = _tabs.Items.ToList().FindIndex(x => x.Id == id);
        _w.MoveTabIndicator(Math.Max(0, index), changed);
        if (changed && _mode == ShellMode.Expanded && Motion.Enabled) FadeIn(slot);
        _vm.IsHomeSelected = id == "home";
        if (id != "home") IsEditMode = false;
        _general.LastTab = id;
        if (id == _activeTab) return;
        _activeTab = id;
        TabChanged?.Invoke(id);
    }

    static void FadeIn(Border slot)
    {
        var d = TimeSpan.FromMilliseconds(180);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        slot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
        ((TranslateTransform)slot.RenderTransform).BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(6, 0, d) { EasingFunction = ease, FillBehavior = FillBehavior.Stop });
    }

    // ---------- settings reactions ----------

    void OnSetting(object? s, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(GeneralSettings.RecordingHotkey)) { RegisterHotkeys(); return; }
        if (e.PropertyName is nameof(GeneralSettings.ToggleHotkeyTaken) or nameof(GeneralSettings.GameModeHotkeyTaken)) return; // runtime only
        _store.Save("general", _general);
        switch (e.PropertyName)
        {
            case nameof(GeneralSettings.MonitorIndex): _w.SetMonitor(_general.MonitorIndex); break;
            case nameof(GeneralSettings.AccentColor) or nameof(GeneralSettings.Theme): ThemeManager.Apply(_general); break;
            case nameof(GeneralSettings.ReduceMotion): Motion.Refresh(_general.ReduceMotion); break;
            case nameof(GeneralSettings.ProfileName) or nameof(GeneralSettings.ProfileImagePath): LoadProfile(); break;
            case nameof(GeneralSettings.StartWithWindows): Autostart.Set(_general.StartWithWindows); break;
            case nameof(GeneralSettings.ToggleHotkey) or nameof(GeneralSettings.GameModeHotkey): RegisterHotkeys(); break;
            case nameof(GeneralSettings.Pinned):
                if (_general.Pinned) _leave?.Stop();
                else if (!_hovering) StartLeave();
                break;
        }
    }

    void RegisterHotkeys()
    {
        _hotkeys.Unregister(_toggleKey);
        _hotkeys.Unregister(_gameKey);
        if (_general.RecordingHotkey) return; // the Settings recorder is listening: global hotkeys would swallow the keys
        _toggleKey = _general.ToggleHotkey;
        _gameKey = _general.GameModeHotkey;
        _general.ToggleHotkeyTaken = !_hotkeys.Register(_toggleKey, ToggleFromUser);
        _general.GameModeHotkeyTaken = !_hotkeys.Register(_gameKey, GameMode.CycleOverride);
    }

    nint SettingsHook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == Native.WM_SETTINGCHANGE)
        {
            Motion.Refresh(_general.ReduceMotion);
            if (_general.Theme == ThemeChoice.System && lParam != 0 &&
                System.Runtime.InteropServices.Marshal.PtrToStringUni(lParam) == "ImmersiveColorSet") ThemeManager.Apply(_general);
        }
        return 0;
    }

    void LoadProfile()
    {
        var name = _general.ProfileName?.Trim() ?? "";
        _vm.ProfileInitial = name.Length > 0 ? name[..1].ToUpperInvariant() : "?";
        _vm.ProfileImage = null;
        var p = _general.ProfileImagePath;
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
            _vm.ProfileImage = bmp;
        }
        catch (Exception ex) { Log.Warn("Profile image unreadable", ex); }
    }
}
