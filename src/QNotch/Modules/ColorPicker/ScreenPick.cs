using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace QNotch.Modules.ColorPicker;

/// <summary>
/// One pick: a small preview follows the pointer and shows the color under it; left click picks, right click cancels. The click is
/// swallowed by a low-level mouse hook that exists only while picking, so the app under the pointer never sees it. UI thread only.
/// </summary>
internal static unsafe partial class ScreenPick
{
    const int WH_MOUSE_LL = 14, WM_LBUTTONDOWN = 0x201, WM_LBUTTONUP = 0x202, WM_RBUTTONDOWN = 0x204, WM_RBUTTONUP = 0x205;
    const int GWL_EXSTYLE = -20, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    const uint SWP_NOSIZE = 1, SWP_NOZORDER = 4, SWP_NOACTIVATE = 0x10;

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    [LibraryImport("user32.dll", EntryPoint = "SetWindowsHookExW")] private static partial nint SetWindowsHookEx(int id, delegate* unmanaged<int, nint, nint, nint> proc, nint module, uint thread);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool UnhookWindowsHookEx(nint hook);
    [LibraryImport("user32.dll")] private static partial nint CallNextHookEx(nint hook, int code, nint w, nint l);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool GetCursorPos(out POINT p);
    [LibraryImport("user32.dll")] private static partial nint GetDC(nint hwnd);
    [LibraryImport("user32.dll")] private static partial int ReleaseDC(nint hwnd, nint dc);
    [LibraryImport("gdi32.dll")] private static partial uint GetPixel(nint dc, int x, int y);
    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static partial nint GetWindowLong(nint hwnd, int index);
    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static partial nint SetWindowLong(nint hwnd, int index, nint value);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool GetWindowRect(nint hwnd, out RECT r);
    [LibraryImport("user32.dll")] private static partial int GetSystemMetrics(int index);
    [LibraryImport("kernel32.dll", EntryPoint = "GetModuleHandleW")] private static partial nint GetModuleHandle(nint name);

    static nint _hook;
    static bool _ending; // the button went down: swallow its release, then unhook
    static Action<Color?>? _done;
    static Window? _preview;
    static nint _previewHwnd;
    static Border _swatch = null!;
    static TextBlock _label = null!;
    static DispatcherTimer? _timer;
    static uint _last = uint.MaxValue;

    public static bool Active => _hook != 0;

    /// <summary><paramref name="done"/> gets the picked color, or null when cancelled.</summary>
    public static void Start(Action<Color?> done)
    {
        if (Active) return;
        _hook = SetWindowsHookEx(WH_MOUSE_LL, &Hook, GetModuleHandle(0), 0);
        if (_hook == 0) { done(null); return; }
        _done = done;
        _ending = false;
        _last = uint.MaxValue;
        ShowPreview();
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(40), DispatcherPriority.Input, (_, _) => Track(), Dispatcher.CurrentDispatcher);
        Track();
    }

    public static void Cancel() { if (Active && !_ending) Finish(null); }

    [UnmanagedCallersOnly]
    static nint Hook(int code, nint w, nint l)
    {
        if (code < 0) return CallNextHookEx(0, code, w, l);
        try { if (Handle((int)w, (POINT*)l)) return 1; }
        catch (Exception ex) { QNotch.Core.Log.Warn("Color pick failed", ex); }
        return CallNextHookEx(0, code, w, l);
    }

    /// <summary>True when the mouse message was consumed.</summary>
    static bool Handle(int msg, POINT* p)
    {
        switch (msg)
        {
            case WM_LBUTTONDOWN when !_ending:
                _ending = true;
                Finish(ToColor(Pixel(p->X, p->Y)));
                return true;
            case WM_RBUTTONDOWN when !_ending:
                _ending = true;
                Finish(null);
                return true;
            case WM_LBUTTONUP or WM_RBUTTONUP when _ending:
                UnhookWindowsHookEx(_hook);
                _hook = 0;
                return true;
            case WM_LBUTTONDOWN or WM_RBUTTONDOWN:
                return true;
        }
        return false;
    }

    static void Finish(Color? color)
    {
        _timer?.Stop();
        _timer = null;
        if (!_ending) { UnhookWindowsHookEx(_hook); _hook = 0; } // cancelled from the keyboard: no button release to wait for
        var done = _done;
        _done = null;
        if (color is null) { ClosePreview(); }
        else
        {
            // Confirm in place, then go away.
            _label.Text = "Copied";
            var t = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
            t.Tick += (_, _) => { t.Stop(); if (_timer is null) ClosePreview(); }; // unless the next pick already runs
            t.Start();
        }
        // Not inside the hook callback: clipboard and settings work must not delay the mouse.
        Dispatcher.CurrentDispatcher.BeginInvoke(() => done?.Invoke(color));
    }

    static uint Pixel(int x, int y)
    {
        var dc = GetDC(0);
        try { return GetPixel(dc, x, y); }
        finally { ReleaseDC(0, dc); }
    }

    static Color ToColor(uint bgr) => Color.FromRgb((byte)bgr, (byte)(bgr >> 8), (byte)(bgr >> 16));
    public static string Hex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    static void Track()
    {
        if (!GetCursorPos(out var p)) return;
        var px = Pixel(p.X, p.Y);
        if (px != _last && px != 0xFFFFFFFF)
        {
            _last = px;
            var c = ToColor(px);
            _swatch.Background = new SolidColorBrush(c);
            _label.Text = Hex(c);
        }
        // Below right of the pointer, flipped at the right and bottom edges of the desktop.
        GetWindowRect(_previewHwnd, out var r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        int right = GetSystemMetrics(76) + GetSystemMetrics(78), bottom = GetSystemMetrics(77) + GetSystemMetrics(79); // virtual screen
        int x = p.X + 20 + w > right ? p.X - 20 - w : p.X + 20, y = p.Y + 20 + h > bottom ? p.Y - 20 - h : p.Y + 20;
        SetWindowPos(_previewHwnd, 0, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    static void ShowPreview()
    {
        ClosePreview();
        _swatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
        _swatch.SetResourceReference(Border.BorderBrushProperty, "StrokeStrongBrush");
        _label = new TextBlock { FontSize = 12, FontWeight = FontWeights.SemiBold, MinWidth = 58, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 2, 0) };
        _label.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimaryBrush");
        _label.SetResourceReference(TextBlock.FontFamilyProperty, "UiFont");
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_swatch);
        row.Children.Add(_label);
        var box = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6), BorderThickness = new Thickness(1), Child = row };
        box.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        box.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");

        _preview = new Window
        {
            WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false, ShowActivated = false, Topmost = true, SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.Manual, Left = -10000, Top = -10000, Content = box,
        };
        _preview.SourceInitialized += (s, _) =>
        {
            _previewHwnd = new WindowInteropHelper((Window)s!).Handle;
            SetWindowLong(_previewHwnd, GWL_EXSTYLE, GetWindowLong(_previewHwnd, GWL_EXSTYLE) | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        };
        _preview.Show();
    }

    static void ClosePreview()
    {
        _preview?.Close();
        _preview = null;
    }
}
