using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using QNotch.Core;
using QNotch.Interop;
using QNotch.Shell.GameMode;

namespace QNotch.Shell;

/// <summary>Notification-area icon via Shell_NotifyIcon. Messages arrive on the notch window (no extra window or thread).</summary>
public sealed unsafe class TrayIcon : IDisposable
{
    const int CallbackMessage = Native.WM_APP + 1;
    readonly NotchWindow _w;
    readonly ShellController _shell;
    readonly Action _exit;
    readonly uint _taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
    nint _icon, _iconActive; // active (amber pill): Game mode is forced or the game bar is showing

    public TrayIcon(NotchWindow window, ShellController shell, Action exit)
    {
        _w = window; _shell = shell; _exit = exit;
        var size = Math.Max(16, Native.GetSystemMetrics(Native.SM_CXSMICON));
        _icon = AppIcon.CreateHIcon(size);
        _iconActive = AppIcon.CreateHIcon(size, System.Windows.Media.Color.FromRgb(0xF5, 0xA5, 0x24));
        _w.Source.AddHook(Hook);
        Add();
        shell.ModeChanged += _ => UpdateTip();
        shell.GameMode.OverrideChanged += _ => UpdateTip();
    }

    NOTIFYICONDATAW Data(uint flags)
    {
        var d = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW), hWnd = _w.Hwnd, uID = 1, uFlags = flags,
            uCallbackMessage = CallbackMessage, hIcon = _shell.Mode == ShellMode.GameBar || _shell.GameMode.Override != GameModeOverride.Auto ? _iconActive : _icon,
        };
        var mode = _shell.GameMode.Override switch { GameModeOverride.ForceOn => "Force on", GameModeOverride.ForceOff => "Force off", _ => "Auto" };
        var tip = $"QNotch\nGame mode: {mode}{(_shell.Mode == ShellMode.GameBar ? ", game bar showing" : "")}";
        for (var i = 0; i < Math.Min(tip.Length, 127); i++) d.szTip[i] = tip[i];
        return d;
    }

    void Add() { var d = Data(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP); Native.Shell_NotifyIcon(Native.NIM_ADD, ref d); }
    void UpdateTip() { var d = Data(Native.NIF_TIP | Native.NIF_ICON); Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref d); }

    nint Hook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            handled = true;
            var ev = (int)(lParam & 0xFFFF);
            if (ev == Native.WM_LBUTTONUP) _shell.ToggleFromUser();
            else if (ev == Native.WM_RBUTTONUP) ShowMenu();
        }
        else if ((uint)msg == _taskbarCreated) Add();
        return 0;
    }

    void ShowMenu()
    {
        _w.EnableKeyboard(); // menus need a foreground owner to dismiss on outside click
        var m = new ContextMenu { PlacementTarget = _w, Placement = PlacementMode.MousePoint };
        if (_shell.Mode != ShellMode.GameBar) m.Items.Add(Item("Open panel", () => _shell.OpenPanel()));
        m.Items.Add(Item("Settings", () => _shell.OpenSettings()));
        m.Items.Add(new Separator());
        foreach (var o in Enum.GetValues<GameModeOverride>())
        {
            var mode = o;
            var label = o switch { GameModeOverride.Auto => "Game mode: Auto", GameModeOverride.ForceOn => "Game mode: Force on", _ => "Game mode: Force off" };
            var it = Item(label, () => _shell.GameMode.Override = mode);
            it.IsChecked = _shell.GameMode.Override == o;
            m.Items.Add(it);
        }
        m.Items.Add(new Separator());
        m.Items.Add(Item("Exit", _exit));
        // Keep keyboard focus if "Open panel" was chosen, so Esc and an outside click dismiss the panel.
        m.Closed += (_, _) => { if (_shell.Mode != ShellMode.Expanded) _w.DisableKeyboard(); };
        m.IsOpen = true;
    }

    static MenuItem Item(string header, Action click)
    {
        var i = new MenuItem { Header = header };
        i.Click += (_, _) => click();
        return i;
    }

    public void Dispose()
    {
        var d = Data(0);
        Native.Shell_NotifyIcon(Native.NIM_DELETE, ref d);
        if (_icon != 0) { Native.DestroyIcon(_icon); _icon = 0; }
        if (_iconActive != 0) { Native.DestroyIcon(_iconActive); _iconActive = 0; }
    }
}
