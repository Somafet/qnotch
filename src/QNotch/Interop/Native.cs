using System.Runtime.InteropServices;

namespace QNotch.Interop;

[StructLayout(LayoutKind.Sequential)]
public struct RECT
{
    public int Left, Top, Right, Bottom;
    public readonly int Width => Right - Left;
    public readonly int Height => Bottom - Top;
}

[StructLayout(LayoutKind.Sequential)]
public struct MONITORINFO
{
    public uint cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
}

[StructLayout(LayoutKind.Sequential)]
public unsafe struct NOTIFYICONDATAW
{
    public uint cbSize;
    public nint hWnd;
    public uint uID;
    public uint uFlags;
    public uint uCallbackMessage;
    public nint hIcon;
    public fixed char szTip[128];
    public uint dwState;
    public uint dwStateMask;
    public fixed char szInfo[256];
    public uint uVersion;
    public fixed char szInfoTitle[64];
    public uint dwInfoFlags;
    public Guid guidItem;
    public nint hBalloonIcon;
}

[StructLayout(LayoutKind.Sequential)]
public struct ICONINFO
{
    public int fIcon;
    public int xHotspot, yHotspot;
    public nint hbmMask, hbmColor;
}

[StructLayout(LayoutKind.Sequential)]
public struct MEMORYSTATUSEX
{
    public uint dwLength, dwMemoryLoad;
    public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
}

[StructLayout(LayoutKind.Sequential)]
public struct SYSTEM_POWER_STATUS
{
    public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
    public uint BatteryLifeTime, BatteryFullLifeTime;
}

/// <summary>
/// P/Invoke surface shared by the shell and modules. It is a shared file: feature agents do NOT edit it.
/// Need another API? Declare it in your own module folder in a class named after the module (for example GameModeNative),
/// never in this class, so parallel branches cannot collide.
/// </summary>
public static unsafe partial class Native
{
    // Window styles
    public const int GWL_STYLE = -16, GWL_EXSTYLE = -20;
    public const long WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_LAYERED = 0x80000, WS_EX_NOACTIVATE = 0x08000000;

    // SetWindowPos
    public static readonly nint HWND_TOPMOST = -1;
    public const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_FRAMECHANGED = 0x20, SWP_SHOWWINDOW = 0x40;

    // Messages
    public const int WM_DISPLAYCHANGE = 0x7E, WM_DPICHANGED = 0x2E0, WM_HOTKEY = 0x312, WM_SETTINGCHANGE = 0x1A, WM_APP = 0x8000,
        WM_LBUTTONUP = 0x202, WM_RBUTTONUP = 0x205, WM_CLIPBOARDUPDATE = 0x31D, WM_MOUSEACTIVATE = 0x21;

    // WinEvent
    public const uint EVENT_SYSTEM_FOREGROUND = 0x3, WINEVENT_OUTOFCONTEXT = 0x0, WINEVENT_SKIPOWNPROCESS = 0x2;

    // Shell_NotifyIcon
    public const uint NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4;

    // SHQueryUserNotificationState results
    public const int QUNS_NOT_PRESENT = 1, QUNS_BUSY = 2, QUNS_RUNNING_D3D_FULL_SCREEN = 3, QUNS_PRESENTATION_MODE = 4,
        QUNS_ACCEPTS_NOTIFICATIONS = 5, QUNS_QUIET_TIME = 6, QUNS_APP = 7;

    // Window long / style
    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] public static partial nint GetWindowLongPtr(nint hwnd, int index);
    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] public static partial nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool SetForegroundWindow(nint hwnd);
    [LibraryImport("user32.dll")] public static partial nint GetForegroundWindow();
    [LibraryImport("user32.dll")] public static partial nint GetDesktopWindow();
    [LibraryImport("user32.dll")] public static partial nint GetShellWindow();
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool IsWindowVisible(nint hwnd);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool GetWindowRect(nint hwnd, out RECT rect);
    [LibraryImport("user32.dll")] public static partial uint GetWindowThreadProcessId(nint hwnd, out uint pid);
    [LibraryImport("user32.dll", EntryPoint = "GetClassNameW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial int GetClassName(nint hwnd, [Out] char[] buffer, int max);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool GetCursorPos(out int x, out int y);
    [LibraryImport("user32.dll", EntryPoint = "RegisterWindowMessageW", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint RegisterWindowMessage(string name);

    // Hotkeys
    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint vk);
    [LibraryImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool UnregisterHotKey(nint hwnd, int id);

    // Foreground hook (function pointer: no delegate to root)
    [LibraryImport("user32.dll")]
    public static partial nint SetWinEventHook(uint min, uint max, nint hmod,
        delegate* unmanaged<nint, uint, nint, int, int, uint, uint, void> proc, uint pid, uint tid, uint flags);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool UnhookWinEvent(nint hook);

    // Monitors
    [LibraryImport("user32.dll")] public static partial nint MonitorFromWindow(nint hwnd, uint flags);
    [LibraryImport("user32.dll", EntryPoint = "GetMonitorInfoW")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetMonitorInfo(nint monitor, ref MONITORINFO info);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool EnumDisplayMonitors(nint hdc, nint clip, delegate* unmanaged<nint, nint, nint, nint, int> proc, nint data);
    [LibraryImport("shcore.dll")] public static partial int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);

    // Tray + icons
    [LibraryImport("shell32.dll", EntryPoint = "Shell_NotifyIconW")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool Shell_NotifyIcon(uint message, ref NOTIFYICONDATAW data);
    [LibraryImport("user32.dll")] public static partial nint CreateIconIndirect(ref ICONINFO info);
    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool DestroyIcon(nint icon);
    [LibraryImport("gdi32.dll")] public static partial nint CreateBitmap(int w, int h, uint planes, uint bpp, byte* bits);
    [LibraryImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool DeleteObject(nint obj);

    // Shell state (game mode)
    [LibraryImport("shell32.dll")] public static partial int SHQueryUserNotificationState(out int state);

    // System stats
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [LibraryImport("iphlpapi.dll")] public static partial int GetIfTable2(out nint table);
    [LibraryImport("iphlpapi.dll")] public static partial void FreeMibTable(nint table);

    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetProcessWorkingSetSize(nint process, nint min, nint max);

    // DWM (dark title bar for the settings window)
    [LibraryImport("dwmapi.dll")] public static partial int DwmSetWindowAttribute(nint hwnd, int attr, ref int value, int size);

    public static string ClassNameOf(nint hwnd)
    {
        var buf = new char[256];
        var n = GetClassName(hwnd, buf, buf.Length);
        return new string(buf, 0, n);
    }
}
