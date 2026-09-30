using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>
/// The overlay window. Fixed size (max panel bounds), top-center of the chosen monitor; transparent pixels are hit-test transparent.
/// Per frame during open/close only the Surface size, corner radius and two opacities change; content is never re-measured.
/// Nothing runs while idle: the Rendering hook exists only during an animation.
/// </summary>
public partial class NotchWindow : Window
{
    public const double WinW = 760, WinH = 430, PanelW = 720, PanelH = 380, PillH = 38, PillR = 16, PanelR = 26;
    const double OpenMs = 240, CloseMs = 180, TabW = 40, TabGap = 2;

    nint _hwnd, _prevForeground;
    HwndSource _src = null!;
    bool _kb, _gameBar, _pillDirty;
    int _monitorIndex;
    double _offX, _offY, _gameH = 22, _gameOpacity = 0.7, _gameShift;

    // Animation state. Frames come from CompositionTarget.Rendering (vsync paced), de-duplicated by RenderingTime because the
    // event fires several times per frame for layered windows. The hook exists only while an animation runs. Measured on a
    // 144 Hz display: about 95 fps average; each frame re-renders the whole layered surface (roughly 5 ms of CPU).
    bool _animating;
    double _open, _from, _to, _durMs, _pillW = 420;
    long _t0;
    TimeSpan _lastFrame;

    public NotchWindow()
    {
        InitializeComponent();
        Surface.MouseEnter += (_, _) => HoverEntered?.Invoke();
        Surface.MouseLeave += (_, _) => HoverLeft?.Invoke();
        Glance.MouseEnter += (_, _) => HoverEntered?.Invoke();
        Glance.MouseLeave += (_, _) => HoverLeft?.Invoke();
        // Bubbling KeyDown: an open ComboBox or menu gets Esc first.
        KeyDown += (_, e) => { if (e.Key == Key.Escape && !e.Handled) { EscPressed?.Invoke(); e.Handled = true; } };
        Deactivated += (_, _) => { if (_kb) { DisableKeyboard(); KeyboardFocusLost?.Invoke(); } };
        Glance.IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue && Motion.Enabled)
                Glance.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)) { FillBehavior = FillBehavior.Stop });
        };
        Surface.SizeChanged += (_, _) => { if (_gameBar) ClampGameShift(); };
        // OLE drag: mouse events are suspended during a drag, so the drag events stand in for hover.
        Surface.DragEnter += (_, e) => OnDrag(e, enter: true);
        Surface.DragOver += (_, e) => OnDrag(e, enter: false);
        Surface.DragLeave += (_, _) => DragLeft?.Invoke();
        Surface.Drop += (_, e) =>
        {
            if (e.Handled || e.Data.GetData(DataFormats.FileDrop) is not string[] files) return;
            e.Handled = true;
            FilesDropped?.Invoke(files);
        };
    }

    public nint Hwnd => _hwnd;
    public HwndSource Source => _src;
    public bool IsGameBar => _gameBar;
    public bool HasKeyboard => _kb;
    public nint MonitorHandle { get; private set; }

    public event Action? HoverEntered, HoverLeft, EscPressed, KeyboardFocusLost, DragLeft;
    /// <summary>File drag over the surface: arg is true on the first enter. Handler returns whether files are accepted.</summary>
    public event Func<bool, bool>? FileDragOver;
    public event Action<string[]>? FilesDropped;

    void OnDrag(DragEventArgs e, bool enter)
    {
        if (e.Handled) return;
        var accept = e.Data.GetDataPresent(DataFormats.FileDrop) && FileDragOver?.Invoke(enter) == true;
        e.Effects = accept ? DragDropEffects.Copy | DragDropEffects.Link : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>Creates the HWND (without showing) and applies the extended styles. Call once, before Show().</summary>
    public void InitHandle()
    {
        _hwnd = new WindowInteropHelper(this).EnsureHandle();
        _src = HwndSource.FromHwnd(_hwnd)!;
        _src.AddHook(WndProc);
        // WS_EX_LAYERED comes from AllowsTransparency; topmost is applied through SetWindowPos (Topmost="True").
        SetExStyle(Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE, 0);
    }

    void SetExStyle(long add, long remove)
    {
        var s = Native.GetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE);
        Native.SetWindowLongPtr(_hwnd, Native.GWL_EXSTYLE, (nint)((s | add) & ~remove));
    }

    nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_DPICHANGED:
            case Native.WM_DISPLAYCHANGE:
                // WPF applies its own suggested rect first; re-anchor afterwards.
                Dispatcher.BeginInvoke(DispatcherPriority.Send, () => { Reposition(); ReassertTopmost(); });
                break;
            case Native.WM_MOUSEACTIVATE when !_kb:
                handled = true;
                return 3; // MA_NOACTIVATE
        }
        return 0;
    }

    public void ReassertTopmost() =>
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);

    /// <summary>
    /// Anchors the fixed-size window at the top-center of the chosen monitor (full monitor bounds, physical pixels).
    /// In game bar mode the offsets move the window; whatever the monitor edge prevents is applied as a shift of the bar
    /// inside the window, so the bar can reach the corners.
    /// </summary>
    public void Reposition()
    {
        var m = Monitors.Get(_monitorIndex);
        MonitorHandle = m.Handle;
        var s = m.Scale;
        int w = (int)Math.Round(WinW * s), h = (int)Math.Round(WinH * s);
        double ox = _gameBar ? _offX : 0, oy = _gameBar ? _offY : 0;
        var center = m.Bounds.Left + m.Bounds.Width / 2.0 + ox * s;
        var x = Math.Clamp((int)Math.Round(center - w / 2.0), m.Bounds.Left, Math.Max(m.Bounds.Left, m.Bounds.Right - w));
        var y = m.Bounds.Top + Math.Clamp((int)Math.Round(oy * s), 0, Math.Max(0, m.Bounds.Height - (int)Math.Round(_gameH * s)));
        _gameShift = (center - (x + w / 2.0)) / s;
        ClampGameShift();
        if (Offscreen) { x = -20000; y = 0; }
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE);
    }

    void ClampGameShift()
    {
        var room = Math.Max(0, (WinW - Surface.ActualWidth) / 2);
        SurfaceShift.X = _gameBar ? Math.Clamp(_gameShift, -room, room) : 0;
    }

    public void SetMonitor(int index) { _monitorIndex = index; Reposition(); }

    /// <summary>True when the pointer is over the pill/panel right now (asks the OS: WPF hover state is stale after a drag).</summary>
    public bool IsPointerOver()
    {
        if (!Native.GetCursorPos(out var pt) || !IsVisible) return false;
        var p = Surface.PointFromScreen(new Point(pt.X, pt.Y));
        return p.X >= 0 && p.Y >= 0 && p.X < Surface.ActualWidth && p.Y < Surface.ActualHeight;
    }

    // ---------- keyboard focus (WS_EX_NOACTIVATE toggle) ----------

    /// <summary>Makes the window activatable and takes the foreground so text input and Esc work.</summary>
    public void EnableKeyboard()
    {
        if (_kb) return;
        _kb = true;
        var fg = Native.GetForegroundWindow();
        _prevForeground = fg == _hwnd ? 0 : fg;
        SetExStyle(0, Native.WS_EX_NOACTIVATE);
        Native.SetForegroundWindow(_hwnd);
        Activate();
    }

    /// <summary>Back to non-activating. If we still own the foreground, hand it back to the app that had it.</summary>
    public void DisableKeyboard()
    {
        if (!_kb) return;
        _kb = false;
        SetExStyle(Native.WS_EX_NOACTIVATE, 0);
        if (_prevForeground != 0 && Native.GetForegroundWindow() == _hwnd && Native.IsWindowVisible(_prevForeground))
            Native.SetForegroundWindow(_prevForeground);
        _prevForeground = 0;
    }

    public void SetClickThrough(bool on)
    {
        if (on) SetExStyle(Native.WS_EX_TRANSPARENT, 0);
        else SetExStyle(0, Native.WS_EX_TRANSPARENT);
    }

    // ---------- pill sizing ----------

    double MeasurePill()
    {
        PillLayer.Measure(new Size(double.PositiveInfinity, PillH));
        return Math.Ceiling(PillLayer.DesiredSize.Width / 4) * 4 + 2;
    }

    /// <summary>Call once after the DataContext is set.</summary>
    public void InitPill()
    {
        _pillW = MeasurePill();
        Surface.Width = _pillW;
    }

    /// <summary>Data behind the pill changed: re-measure once (coalesced) and grow/shrink the pill with hysteresis.</summary>
    public void InvalidatePill()
    {
        if (_pillDirty || _gameBar) return;
        _pillDirty = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            _pillDirty = false;
            if (_gameBar || _open > 0 || _animating) return;
            var w = MeasurePill();
            if (w > _pillW || w < _pillW - 24) { _pillW = w; SetCollapsedWidth(w, true); }
        });
    }

    void SetCollapsedWidth(double w, bool animate)
    {
        var from = Surface.ActualWidth;
        Surface.Width = w;
        if (animate && Motion.Enabled && from > 0 && Math.Abs(from - w) > 1)
            Surface.BeginAnimation(WidthProperty, new DoubleAnimation(from, w, TimeSpan.FromMilliseconds(200))
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
    }

    /// <summary>Lays out the hidden panel (every tab, see ShellController) once so no open or tab switch pays a first layout pass.</summary>
    public void WarmUpPanel()
    {
        PanelLayer.Visibility = Visibility.Visible;
        PanelLayer.Opacity = 0;
        PanelLayer.Measure(new Size(PanelW, PanelH));
        PanelLayer.Arrange(new Rect(0, 0, PanelW, PanelH));
        PanelLayer.Visibility = Visibility.Collapsed;
    }

    // ---------- tab indicator ----------

    public void MoveTabIndicator(int index, bool animate)
    {
        var x = index * (TabW + TabGap);
        TabIndicatorShift.BeginAnimation(TranslateTransform.XProperty, null);
        var from = TabIndicatorShift.X;
        TabIndicatorShift.X = x;
        if (animate && Motion.Enabled && _open > 0 && Math.Abs(from - x) > 0.5)
            TabIndicatorShift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(from, x, TimeSpan.FromMilliseconds(220))
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
    }

    // ---------- open / close animation ----------

    public void SetOpen(bool open, bool animate = true)
    {
        if (_gameBar) return;
        Surface.BeginAnimation(WidthProperty, null);
        if (open) PanelLayer.Visibility = Visibility.Visible;
        else
        {
            PillLayer.Visibility = Visibility.Visible;
            _pillW = MeasurePill();
        }
        _from = _open;
        _to = open ? 1 : 0;
        if (!animate || !Motion.Enabled) { StopAnimation(); Apply(_to); Finish(); return; }
        _durMs = (open ? OpenMs : CloseMs) * Math.Max(0.35, Math.Abs(_to - _from));
        _t0 = Stopwatch.GetTimestamp();
        if (!_animating) { _animating = true; CompositionTarget.Rendering += OnRendering; }
    }

    void StopAnimation()
    {
        if (!_animating) return;
        _animating = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    void OnRendering(object? s, EventArgs e)
    {
        var rt = ((RenderingEventArgs)e).RenderingTime;
        if (rt == _lastFrame) return; // same frame: nothing new to draw
        _lastFrame = rt;
        var t = (Stopwatch.GetTimestamp() - _t0) * 1000.0 / Stopwatch.Frequency;
        var p = Math.Clamp(t / _durMs, 0, 1);
        var eased = _to > _from ? EaseOutBack(p) : EaseOutCubic(p);
        Apply(_from + (_to - _from) * eased);
        if (p >= 1) { StopAnimation(); Apply(_to); Finish(); }
    }

    // Gentle spring on open (about 3% overshoot), quick settle on close.
    static double EaseOutBack(double p) { const double c1 = 0.7, c3 = c1 + 1; var q = p - 1; return 1 + c3 * q * q * q + c1 * q * q; }
    static double EaseOutCubic(double p) { var q = 1 - p; return 1 - q * q * q; }
    static double Lerp(double a, double b, double t) => a + (b - a) * t;
    static double Clamp01(double v) => Math.Clamp(v, 0, 1);

    /// <summary>o: 0 = pill, 1 = full panel (may overshoot slightly for the spring feel).</summary>
    void Apply(double o)
    {
        _open = o;
        Surface.Width = Math.Min(Lerp(_pillW, PanelW, o), WinW - 2);
        Surface.Height = Math.Min(Lerp(PillH, PanelH, o), WinH - 4);
        var r = Math.Max(0, Lerp(PillR, PanelR, Clamp01(o)));
        Surface.CornerRadius = new CornerRadius(0, 0, r, r);
        PillLayer.Opacity = 1 - Clamp01(o / 0.3);
        var po = Clamp01((o - 0.3) / 0.55);
        PanelLayer.Opacity = po;
        PanelShift.Y = (1 - po) * -8;
    }

    void Finish()
    {
        _open = _to;
        if (_to == 0)
        {
            PanelLayer.Visibility = Visibility.Collapsed;
            PillLayer.Opacity = 1;
            Surface.Width = _pillW;
        }
        else
        {
            PillLayer.Visibility = Visibility.Collapsed;
            PanelLayer.Opacity = 1;
            PanelShift.Y = 0;
        }
    }

    // ---------- game bar ----------

    public void EnterGameBar()
    {
        StopAnimation();
        Surface.BeginAnimation(WidthProperty, null);
        _open = 0; _to = 0; _gameBar = true;
        PanelLayer.Visibility = Visibility.Collapsed;
        PillLayer.Visibility = Visibility.Collapsed;
        GameBarHost.Visibility = Visibility.Visible;
        ApplyGameLayout();
    }

    public void ExitGameBar()
    {
        _gameBar = false;
        GameBarHost.Visibility = Visibility.Collapsed;
        PillLayer.Visibility = Visibility.Visible;
        PillLayer.Opacity = 1;
        Surface.Height = PillH;
        Surface.CornerRadius = new CornerRadius(0, 0, PillR, PillR);
        _pillW = MeasurePill();
        Surface.Width = _pillW;
        Fade(1);
        Reposition();
    }

    public void SetGameBarView(UIElement? view) { GameBarHost.Content = view; }

    public void SetGameBarLayout(double height, double opacity, double offX, double offY)
    {
        _gameH = Math.Max(12, height); _gameOpacity = Math.Clamp(opacity, 0.1, 1); _offX = offX; _offY = offY;
        if (_gameBar) ApplyGameLayout();
    }

    void ApplyGameLayout()
    {
        Surface.Width = double.NaN;
        Surface.Height = _gameH;
        var r = Math.Min(_gameH / 2, 12);
        // Away from the top edge the bar is a free-floating capsule: round all corners.
        Surface.CornerRadius = _offY > 0 ? new CornerRadius(r) : new CornerRadius(0, 0, r, r);
        Surface.BorderThickness = _offY > 0 ? new Thickness(1) : new Thickness(1, 0, 1, 1);
        Fade(_gameOpacity);
        Reposition();
    }

    void Fade(double to)
    {
        if (!_gameBar) Surface.BorderThickness = new Thickness(1, 0, 1, 1);
        var from = Surface.Opacity;
        Surface.Opacity = to;
        if (Motion.Enabled && Math.Abs(from - to) > 0.01)
            Surface.BeginAnimation(OpacityProperty, new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(150)) { FillBehavior = FillBehavior.Stop });
    }

    // ---------- snapshot support (dev tool, see Snapshot.cs) ----------

    /// <summary>Snapshot mode: keep the window off every monitor.</summary>
    internal bool Offscreen { get; init; }
    internal FrameworkElement RootElement => Root;
}
