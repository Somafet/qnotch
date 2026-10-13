using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using QNotch.Core;
using QNotch.Core.Updates;
using QNotch.Interop;
using QNotch.Shell.GameMode;

namespace QNotch.Shell;

/// <summary>Notification-area icon via Shell_NotifyIcon. Messages arrive on the notch window (no extra window or thread).</summary>
public sealed unsafe class TrayIcon : IDisposable
{
    const int CallbackMessage = Native.WM_APP + 1;
    const uint NotifyInfo = 0x10, InfoIcon = 0x1, RespectQuietTime = 0x80;
    const int BalloonUserClick = 0x405;
    readonly NotchWindow _w;
    readonly ShellController _shell;
    readonly Shortcuts _shortcuts;
    readonly Action _exit;
    readonly UpdateService _updates;
    readonly uint _taskbarCreated = Native.RegisterWindowMessage("TaskbarCreated");
    nint _icon, _iconActive; // active (amber pill): Game mode is forced or the game bar is showing

    internal TrayIcon(NotchWindow window, ShellController shell, Shortcuts shortcuts, Action exit, UpdateService updates)
    {
        _w = window; _shell = shell; _shortcuts = shortcuts; _exit = exit;
        _updates = updates;
        var size = Math.Max(16, Native.GetSystemMetrics(Native.SM_CXSMICON));
        _icon = AppIcon.CreateHIcon(size);
        _iconActive = AppIcon.CreateHIcon(size, System.Windows.Media.Color.FromRgb(0xF5, 0xA5, 0x24));
        _w.Source.AddHook(Hook);
        Add();
        shell.ModeChanged += _ => { UpdateTip(); NotifyUpdate(); };
        shell.GameMode.OverrideChanged += _ => UpdateTip();
        _updates.State.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(UpdateState.AvailableVersion)) UpdateTip(); };
        _updates.UpdateAvailable += NotifyUpdate;
    }

    NOTIFYICONDATAW Data(uint flags)
    {
        var d = new NOTIFYICONDATAW
        {
            cbSize = (uint)sizeof(NOTIFYICONDATAW), hWnd = _w.Hwnd, uID = 1, uFlags = flags,
            uCallbackMessage = CallbackMessage, hIcon = _shell.Mode == ShellMode.GameBar || _shell.GameMode.Override != GameModeOverride.Auto ? _iconActive : _icon,
        };
        var tip = $"QNotch\nGame mode: {Label(_shell.GameMode.Override)}{(_shell.Mode == ShellMode.GameBar ? ", game bar showing" : "")}";
        if (_updates.State.HasUpdate) tip += $"\nUpdate available: {_updates.State.AvailableVersion}";
        for (var i = 0; i < Math.Min(tip.Length, 127); i++) d.szTip[i] = tip[i];
        return d;
    }

    void Add() { var d = Data(Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP); Native.Shell_NotifyIcon(Native.NIM_ADD, ref d); }
    void UpdateTip() { var d = Data(Native.NIF_TIP | Native.NIF_ICON); Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref d); }

    void NotifyUpdate()
    {
        if (!_updates.ShouldNotify || _shell.Mode == ShellMode.GameBar) return;
        // Leave the update pending during fullscreen games, presentations and Windows quiet time.
        if (Native.SHQueryUserNotificationState(out var state) >= 0 && state != Native.QUNS_ACCEPTS_NOTIFICATIONS) return;
        var d = Data(NotifyInfo);
        var title = "QNotch update available";
        var message = $"QNotch {_updates.State.AvailableVersion} is ready. Click to review the update and choose Update and restart.";
        for (var i = 0; i < Math.Min(title.Length, 63); i++) d.szInfoTitle[i] = title[i];
        for (var i = 0; i < Math.Min(message.Length, 255); i++) d.szInfo[i] = message[i];
        d.dwInfoFlags = InfoIcon | RespectQuietTime;
        if (Native.Shell_NotifyIcon(Native.NIM_MODIFY, ref d)) _updates.MarkNotified();
    }

    nint Hook(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            handled = true;
            var ev = (int)(lParam & 0xFFFF);
            if (ev == Native.WM_LBUTTONUP) _shell.ToggleFromUser();
            else if (ev == Native.WM_RBUTTONUP) ShowMenu();
            else if (ev == BalloonUserClick) _shell.OpenSettings("updates");
        }
        else if ((uint)msg == _taskbarCreated) Add();
        return 0;
    }

    void ShowMenu()
    {
        _w.EnableKeyboard(); // menus need a foreground owner to dismiss on outside click
        // No placement target: the menu would take the notch window's DPI, wrong when the notch is on another monitor.
        var m = new ContextMenu { Placement = PlacementMode.MousePoint };
        if (_shell.Mode != ShellMode.GameBar)
        {
            var open = Item("Open QNotch", () => _shell.OpenPanel());
            open.InputGestureText = _shortcuts.Find("toggle")?.Gesture ?? "";
            m.Items.Add(open);
        }
        m.Items.Add(Item("Settings", () => _shell.OpenSettings()));
        m.Items.Add(Item(_updates.State.HasUpdate ? $"Update to {_updates.State.AvailableVersion}…" : "Updates…",
            () => _shell.OpenSettings("updates")));
        m.Items.Add(new Separator());
        m.Items.Add(new MenuItem { Header = "Game mode", Style = (Style)Application.Current.FindResource("MenuHeader") });
        foreach (var o in Enum.GetValues<GameModeOverride>())
        {
            var mode = o;
            var it = Item(Label(o), () => _shell.GameMode.Override = mode);
            it.IsChecked = _shell.GameMode.Override == o;
            m.Items.Add(it);
        }
        m.Items.Add(new Separator());
        m.Items.Add(Item("Quit QNotch", _exit));
        // Keep keyboard focus if "Open panel" was chosen, so Esc and an outside click dismiss the panel.
        m.Closed += (_, _) => { if (_shell.Mode != ShellMode.Expanded) _w.DisableKeyboard(); };
        m.IsOpen = true;
    }

    static string Label(GameModeOverride o) => o switch { GameModeOverride.ForceOn => "On", GameModeOverride.ForceOff => "Off", _ => "Auto" };

    static MenuItem Item(string header, Action click)
    {
        var i = new MenuItem { Header = header };
        i.Click += (_, _) => click();
        return i;
    }

    public void Dispose()
    {
        _updates.UpdateAvailable -= NotifyUpdate;
        var d = Data(0);
        Native.Shell_NotifyIcon(Native.NIM_DELETE, ref d);
        if (_icon != 0) { Native.DestroyIcon(_icon); _icon = 0; }
        if (_iconActive != 0) { Native.DestroyIcon(_iconActive); _iconActive = 0; }
    }
}
