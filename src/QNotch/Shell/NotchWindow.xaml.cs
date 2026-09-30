using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
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
    public const double WinW = 760, WinH = 430, PanelW = 720, PanelH = 380, PillH = 40, PillR = 16, PanelR = 28;
    const double OpenMs = 220, CloseMs = 180;

    nint _hwnd;
    HwndSource _src = null!;
    bool _kb, _gameBar, _pillDirty;
    int _monitorIndex;
    double _offX, _offY, _gameH = 22, _gameOpacity = 0.7;

    // animation state
    bool _animating;
    double _open, _from, _to, _durMs, _pillW = 420;
    long _t0;

    public NotchWindow()
    {
        InitializeComponent();
        Surface.MouseEnter += (_, _) => HoverEntered?.Invoke();
        Surface.MouseLeave += (_, _) => HoverLeft?.Invoke();
        Glance.MouseEnter += (_, _) => HoverEntered?.Invoke();
        Glance.MouseLeave += (_, _) => HoverLeft?.Invoke();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { EscPressed?.Invoke(); e.Handled = true; } };
        Deactivated += (_, _) => { if (_kb) { DisableKeyboard(); KeyboardFocusLost?.Invoke(); } };
        Glance.IsVisibleChanged += (_, e) =>
        {
            if ((bool)e.NewValue && Motion.Enabled)
                Glance.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(160)) { FillBehavior = FillBehavior.Stop });
        };
    }

    public nint Hwnd => _hwnd;
    public HwndSource Source => _src;
    public bool IsGameBar => _gameBar;
    public bool HasKeyboard => _kb;

    public event Action? HoverEntered, HoverLeft, EscPressed, KeyboardFocusLost;

    /// <summary>Creates the HWND (without showing) and applies the extended styles. Call once, before Show().</summary>
    public void InitHandle()
    {
        _hwnd = new WindowInteropHelper(this).EnsureHandle();
        _src = HwndSource.FromHwnd(_hwnd)!;
        _src.AddHook(WndProc);
        SetExStyle(Native.WS_EX_TOOLWINDOW | Native.WS_EX_TOPMOST | Native.WS_EX_NOACTIVATE, 0);
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

    /// <summary>Anchors the fixed-size window at the top-center of the chosen monitor (full monitor bounds, physical pixels).</summary>
    public void Reposition()
    {
        var m = Monitors.Get(_monitorIndex);
        var s = m.Scale;
        int w = (int)Math.Round(WinW * s), h = (int)Math.Round(WinH * s);
        int x = m.Bounds.Left + (m.Bounds.Width - w) / 2 + (int)Math.Round(_offX * s);
        int y = m.Bounds.Top + Math.Max(0, (int)Math.Round(_offY * s));
        x = Math.Clamp(x, m.Bounds.Left, Math.Max(m.Bounds.Left, m.Bounds.Right - w));
        Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, x, y, w, h, Native.SWP_NOACTIVATE);
    }

    public void SetMonitor(int index) { _monitorIndex = index; Reposition(); }

    // ---------- keyboard focus (WS_EX_NOACTIVATE toggle) ----------

    public void EnableKeyboard()
    {
        if (_kb) return;
        _kb = true;
        SetExStyle(0, Native.WS_EX_NOACTIVATE);
        Native.SetForegroundWindow(_hwnd);
        Activate();
    }

    public void DisableKeyboard()
    {
        if (!_kb) return;
        _kb = false;
        SetExStyle(Native.WS_EX_NOACTIVATE, 0);
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
            Surface.BeginAnimation(WidthProperty, new DoubleAnimation(from, w, TimeSpan.FromMilliseconds(180))
            { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }, FillBehavior = FillBehavior.Stop });
    }

    /// <summary>Lays out the hidden panel once so the first open costs no layout pass.</summary>
    public void WarmUpPanel()
    {
        PanelLayer.Visibility = Visibility.Visible;
        PanelLayer.Opacity = 0;
        UpdateLayout();
        PanelLayer.Visibility = Visibility.Collapsed;
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
        if (!animate || !Motion.Enabled) { StopRendering(); Apply(_to); Finish(); return; }
        _durMs = (open ? OpenMs : CloseMs) * Math.Max(0.35, Math.Abs(_to - _from));
        _t0 = Stopwatch.GetTimestamp();
        if (!_animating) { _animating = true; CompositionTarget.Rendering += OnRendering; }
    }

    void StopRendering()
    {
        if (!_animating) return;
        _animating = false;
        CompositionTarget.Rendering -= OnRendering;
    }

    void OnRendering(object? s, EventArgs e)
    {
        var t = (Stopwatch.GetTimestamp() - _t0) * 1000.0 / Stopwatch.Frequency;
        var p = Math.Clamp(t / _durMs, 0, 1);
        var eased = _to > _from ? EaseOutBack(p) : EaseInOutCubic(p);
        Apply(_from + (_to - _from) * eased);
        if (p >= 1) { StopRendering(); Apply(_to); Finish(); }
    }

    static double EaseOutBack(double p) { const double c1 = 0.9, c3 = c1 + 1; var q = p - 1; return 1 + c3 * q * q * q + c1 * q * q; }
    static double EaseInOutCubic(double p) => p < 0.5 ? 4 * p * p * p : 1 - Math.Pow(-2 * p + 2, 3) / 2;
    static double Lerp(double a, double b, double t) => a + (b - a) * t;
    static double Clamp01(double v) => Math.Clamp(v, 0, 1);

    /// <summary>o: 0 = pill, 1 = full panel (may overshoot slightly for the spring feel).</summary>
    void Apply(double o)
    {
        _open = o;
        Surface.Width = Math.Min(Lerp(_pillW, PanelW, o), WinW - 2);
        Surface.Height = Math.Min(Lerp(PillH, PanelH, o), WinH - 4);
        var r = Math.Max(0, Lerp(PillR, PanelR, o));
        Surface.CornerRadius = new CornerRadius(0, 0, r, r);
        PillLayer.Opacity = 1 - Clamp01(o / 0.3);
        var po = Clamp01((o - 0.35) / 0.5);
        PanelLayer.Opacity = po;
        PanelShift.Y = (1 - po) * 10;
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
        StopRendering();
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
        _offX = _offY = 0;
        Fade(1);
        Reposition();
    }

    public void SetGameBarView(UIElement? view) { GameBarHost.Content = view; }

    public void SetGameBarLayout(double height, double opacity, double offX, double offY)
    {
        _gameH = height; _gameOpacity = opacity; _offX = offX; _offY = offY;
        if (_gameBar) ApplyGameLayout();
    }

    void ApplyGameLayout()
    {
        Surface.Width = double.NaN;
        Surface.Height = _gameH;
        var r = Math.Min(_gameH / 2, 12);
        Surface.CornerRadius = new CornerRadius(0, 0, r, r);
        Fade(_gameOpacity);
        Reposition();
    }

    void Fade(double to)
    {
        var from = Surface.Opacity;
        Surface.Opacity = to;
        if (Motion.Enabled && Math.Abs(from - to) > 0.01)
            Surface.BeginAnimation(OpacityProperty, new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(150)) { FillBehavior = FillBehavior.Stop });
    }
}
