using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Shell.GameMode;

namespace QNotch.Shell;

/// <summary>
/// Moving the notch sideways, out of the way of tab strips. Grab the pill (or the empty part of the open panel's header) and
/// fling it: it keeps its momentum, springs into place and snaps to the center or a screen edge when it lands near one.
/// Carry it onto another display and it moves there (<see cref="GeneralSettings.MonitorIndex"/>).
/// The spot is remembered per app (<see cref="GeneralSettings.NotchSpots"/>) and restored when that app comes to the front.
/// Nothing runs while idle: the spring hooks Rendering only while the notch moves, the app lookup runs on foreground change.
/// </summary>
internal sealed class NotchNudge
{
    const double Slop = 5, Magnet = 56, Throw = 0.16, HeaderH = 58, Edge = 10000;
    // Parts of the Windows shell, not apps: switching to them must not move the notch.
    static readonly HashSet<string> ShellProcesses = new(StringComparer.OrdinalIgnoreCase)
        { "StartMenuExperienceHost.exe", "SearchHost.exe", "ShellExperienceHost.exe", "LockApp.exe" };

    readonly NotchWindow _w;
    readonly ShellController _shell;
    readonly GeneralSettings _gs;
    readonly SettingsStore _store;
    string _app = "";
    bool _armed, _dragging, _reopen;
    double _grabPx, _grabX, _x, _v, _target, _stiffness, _damping;
    readonly List<(long T, double X)> _samples = new();
    bool _animating;
    long _last;

    public NotchNudge(NotchWindow w, ShellController shell, GeneralSettings gs, SettingsStore store, ForegroundWatcher foreground)
    {
        _w = w; _shell = shell; _gs = gs; _store = store;
        _w.Surface.MouseLeftButtonDown += OnDown;
        _w.Surface.MouseMove += OnMove;
        _w.Surface.MouseLeftButtonUp += OnUp;
        _w.Surface.LostMouseCapture += (_, _) =>
        {
            if (_dragging) Drop();
            else if (_armed) _shell.SuppressHover(false); // a press that ended without a drag (released, or capture taken away)
            _armed = false;
        };
        foreground.Changed += OnForeground;
        _shell.ModeChanged += m => { if (m == ShellMode.GameBar) { StopSpring(); _reopen = false; Jump(_target = Spot(_app)); Settled(); } };
    }

    /// <summary>Places the notch for the app in front, without motion. Call once at startup.</summary>
    public void Start()
    {
        _app = AppOf(Native.GetForegroundWindow()) ?? "";
        Jump(_target = Spot(_app));
    }

    /// <summary>Settings, General: forget every app's spot.</summary>
    public void ResetAll()
    {
        _gs.NotchSpots.Clear();
        _store.Save("general", _gs);
        Glide(0, fling: false);
    }

    // ---------- pointer ----------

    void OnDown(object s, MouseButtonEventArgs e)
    {
        if (e.Handled || _shell.Mode == ShellMode.GameBar) return;
        // Open panel: only the header strip is a handle (cards and tabs have their own drags and clicks).
        if (_shell.Mode == ShellMode.Expanded && (_w.PanelLayer.Visibility != Visibility.Visible || e.GetPosition(_w.PanelLayer).Y > HeaderH)) return;
        e.Handled = true;
        if (e.ClickCount == 2) { Remember(0); Glide(0, fling: true); return; }
        _shell.SuppressHover(true); // no dwell opening under a pressed button
        _armed = true;
        _grabPx = CursorPx();
        _grabX = _x = Math.Clamp(_x, -_w.MaxNotchX, _w.MaxNotchX);
        StopSpring();
        _w.Surface.CaptureMouse();
    }

    void OnMove(object s, MouseEventArgs e)
    {
        if (!_armed) return;
        if (!Native.GetCursorPos(out var p)) return;
        if (_dragging && Native.MonitorFromPoint(p, GameModeNative.MONITOR_DEFAULTTONEAREST) is var mon && mon != _w.MonitorHandle) Hop(mon, p.X);
        var dx = (p.X - _grabPx) / _w.Scale;
        if (!_dragging)
        {
            if (Math.Abs(dx) < Slop) return;
            _dragging = true;
            _samples.Clear();
            _reopen = _shell.Mode == ShellMode.Expanded && _gs.Pinned;
            _shell.ClosePanel(); // the panel folds back into the pill you are carrying
        }
        var max = _w.MaxNotchX;
        _x = Math.Clamp(_grabX + dx, -max, max);
        var now = Stopwatch.GetTimestamp();
        _samples.Add((now, _x));
        _samples.RemoveAll(p => Ms(now - p.T) > 80);
        _v = _samples.Count > 1 ? (_x - _samples[0].X) / Math.Max(1, Ms(now - _samples[0].T)) * 1000 : 0;
        _w.SetNotchX(_x, Squash(_v));
    }

    void OnUp(object s, MouseButtonEventArgs e)
    {
        if (!_armed) return;
        e.Handled = true;
        var dragged = _dragging;
        _w.Surface.ReleaseMouseCapture(); // Drop runs from LostMouseCapture
        if (dragged) return;
        _shell.SuppressHover(false);
        if (_shell.Mode == ShellMode.Collapsed) _shell.OpenPanel(); // a plain click opens, no dwell needed
    }

    /// <summary>The pointer crossed onto another display: the notch moves there and stays where the pointer holds it.</summary>
    void Hop(nint mon, double cursorPx)
    {
        var index = Monitors.List().FindIndex(m => m.Handle == mon);
        if (index < 0) return;
        var held = (cursorPx - _w.CenterPx) / _w.Scale - _x;
        _gs.MonitorIndex = index; // the shell saves it and re-anchors the window
        _grabPx = cursorPx;
        _grabX = _x = (cursorPx - _w.CenterPx) / _w.Scale - held;
        _samples.Clear();
    }

    void Drop()
    {
        _dragging = false;
        var max = _w.MaxNotchX;
        // Project the momentum, then let the magnets pull: center, or flush with an edge.
        var land = Math.Clamp(_x + _v * Throw, -max, max);
        if (Math.Abs(land) < Magnet) land = 0;
        else if (max - Math.Abs(land) < Magnet) land = Math.Sign(land) * Edge;
        Remember(land);
        Glide(land, fling: true);
    }

    double CursorPx() => Native.GetCursorPos(out var p) ? p.X : _grabPx;
    static double Ms(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;
    static double Squash(double v) => 1 + Math.Min(Math.Abs(v) / 4000, 0.14);

    // ---------- per-app spots ----------

    void OnForeground(nint hwnd)
    {
        if (_dragging || AppOf(hwnd) is not { } app || app == _app) return;
        _app = app;
        Glide(Spot(app), fling: false);
    }

    /// <summary>The app a foreground window belongs to ("chrome.exe"), or null for windows that must not move the notch:
    /// QNotch itself, the taskbar, desktop, Start and search, windows on another monitor, and processes we cannot read.</summary>
    string? AppOf(nint hwnd)
    {
        if (hwnd == 0 || hwnd == _w.Hwnd) return null;
        if (_w.MonitorHandle != 0 && Native.MonitorFromWindow(hwnd, GameModeNative.MONITOR_DEFAULTTONEAREST) != _w.MonitorHandle) return null;
        var app = GameModeNative.ProcessNameOf(hwnd, out var pid);
        if (app.Length == 0 || pid == (uint)Environment.ProcessId || ShellProcesses.Contains(app)) return null;
        // Explorer is both the shell and the file manager: only its folder windows count as an app.
        if (app.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase) && Native.ClassNameOf(hwnd) != "CabinetWClass") return null;
        return app.ToLowerInvariant();
    }

    double Spot(string app) => _gs.NotchSpots.TryGetValue(app, out var x) ? x : 0;

    void Remember(double x)
    {
        if (_app.Length == 0) return;
        if (x == 0) _gs.NotchSpots.Remove(_app);
        else _gs.NotchSpots[_app] = x;
        _store.Save("general", _gs);
    }

    // ---------- spring ----------

    /// <summary>Springs to <paramref name="x"/> (beyond the max means flush with that edge). A fling bounces, an app switch glides.</summary>
    void Glide(double x, bool fling)
    {
        _target = x;
        if (!Motion.Enabled || _shell.Mode == ShellMode.GameBar) { Jump(x); Settled(); return; }
        _x = Math.Clamp(_x, -_w.MaxNotchX, _w.MaxNotchX);
        _stiffness = fling ? 260 : 170;
        _damping = 2 * Math.Sqrt(_stiffness) * (fling ? 0.55 : 0.9);
        _shell.SuppressHover(true); // the pill sliding under a resting pointer is not a hover
        if (_animating) return;
        _animating = true;
        _last = Stopwatch.GetTimestamp();
        CompositionTarget.Rendering += OnFrame;
    }

    void OnFrame(object? s, EventArgs e)
    {
        var now = Stopwatch.GetTimestamp();
        var dt = Math.Min(Ms(now - _last) / 1000, 1 / 30.0);
        if (dt <= 0) return; // Rendering fires several times per frame for layered windows
        _last = now;
        var max = _w.MaxNotchX;
        var target = Math.Clamp(_target, -max, max);
        _v += (-_stiffness * (_x - target) - _damping * _v) * dt;
        _x += _v * dt;
        // An edge is a wall: the bounce happens against it, never past it.
        if (Math.Abs(_x) > max) { _x = Math.Sign(_x) * max; _v = -_v * 0.35; }
        if (Math.Abs(_x - target) < 0.3 && Math.Abs(_v) < 8) { StopSpring(); Jump(_target); Settled(); return; }
        _w.SetNotchX(_x, Squash(_v));
    }

    void StopSpring()
    {
        if (!_animating) return;
        _animating = false;
        CompositionTarget.Rendering -= OnFrame;
    }

    void Jump(double x)
    {
        _v = 0;
        _x = Math.Clamp(x, -_w.MaxNotchX, _w.MaxNotchX);
        _w.SetNotchX(x);
    }

    void Settled()
    {
        _armed = false;
        _shell.SuppressHover(false);
        if (_reopen) { _reopen = false; _shell.OpenPanel(); }
    }
}
