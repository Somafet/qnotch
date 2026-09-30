using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using QNotch.Interop;

namespace QNotch.Modules.GameMode;

/// <summary>Win32 pieces only Game mode needs (kept out of the shared Native class).</summary>
internal static unsafe partial class GameModeNative
{
    public const long WS_CAPTION = 0xC00000;
    public const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000, MONITOR_DEFAULTTONEAREST = 2;

    [LibraryImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool IsIconic(nint hwnd);
    [LibraryImport("kernel32.dll")] public static partial nint OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint pid);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static partial bool CloseHandle(nint handle);
    [LibraryImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool QueryFullProcessImageName(nint process, uint flags, char* buffer, ref uint size);

    /// <summary>Executable file name of the process owning <paramref name="hwnd"/> ("game.exe"), or "" when it cannot be opened (elevated or protected).</summary>
    public static string ProcessNameOf(nint hwnd, out uint pid)
    {
        Native.GetWindowThreadProcessId(hwnd, out pid);
        if (pid == 0) return "";
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (h == 0) return "";
        try
        {
            var buf = stackalloc char[520];
            uint size = 520;
            return QueryFullProcessImageName(h, 0, buf, ref size) ? Path.GetFileName(new string(buf, 0, (int)size)) : "";
        }
        finally { CloseHandle(h); }
    }

    /// <summary>Gathers the classifier input for a window. Cheap: a handful of Win32 calls, only ever run on foreground or size change.</summary>
    public static WindowFacts Probe(nint hwnd, nint selfHwnd)
    {
        var process = ProcessNameOf(hwnd, out var pid);
        Native.GetWindowRect(hwnd, out var rect);
        var mon = Native.MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        var mi = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        Native.GetMonitorInfo(mon, ref mi);
        Native.SHQueryUserNotificationState(out var notify);
        var style = (long)Native.GetWindowLongPtr(hwnd, Native.GWL_STYLE);
        return new WindowFacts(Native.ClassNameOf(hwnd), process, hwnd == selfHwnd || pid == (uint)Environment.ProcessId,
            Native.IsWindowVisible(hwnd), IsIconic(hwnd), (style & WS_CAPTION) == WS_CAPTION, rect, mi.rcMonitor, notify);
    }
}

/// <summary>
/// EVENT_OBJECT_LOCATIONCHANGE scoped to the foreground process, for "the game switched to fullscreen after launch" (the shell's
/// foreground hook does not report size changes). Out of context, static callback like ForegroundWatcher. A window that is neither moved
/// nor resized produces no events, so this costs nothing while idle.
/// </summary>
internal sealed unsafe class SizeWatcher : IDisposable
{
    static SizeWatcher? _instance;
    nint _hook, _hwnd;

    public event Action? Changed;

    /// <summary>Watch one window's size and position (null hwnd or an unopenable process stops watching).</summary>
    public void Watch(nint hwnd)
    {
        if (hwnd == _hwnd && _hook != 0) return;
        Stop();
        if (hwnd == 0) return;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return;
        _instance = this;
        _hwnd = hwnd;
        _hook = Native.SetWinEventHook(GameModeNative.EVENT_OBJECT_LOCATIONCHANGE, GameModeNative.EVENT_OBJECT_LOCATIONCHANGE, 0, &Callback, pid, 0, Native.WINEVENT_OUTOFCONTEXT);
    }

    public void Stop()
    {
        if (_hook != 0) Native.UnhookWinEvent(_hook);
        _hook = 0; _hwnd = 0;
    }

    [UnmanagedCallersOnly]
    static void Callback(nint hook, uint evt, nint hwnd, int idObject, int idChild, uint thread, uint time)
    {
        // idObject 0 is OBJID_WINDOW: ignore caret and cursor moves, child windows and other windows of the same process.
        try { if (idObject == 0 && _instance is { } s && hwnd == s._hwnd) s.Changed?.Invoke(); } catch { /* never throw into native code */ }
    }

    public void Dispose() => Stop();
}
