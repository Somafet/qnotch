using System.Runtime.InteropServices;

namespace QNotch.Modules.Media;

internal static unsafe partial class MediaNative
{
    [LibraryImport("user32.dll", EntryPoint = "FindWindowExW")] private static partial nint FindWindowEx(nint parent, nint after, nint cls, nint title);
    [LibraryImport("user32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static partial bool IsWindowVisible(nint hwnd);
    [LibraryImport("user32.dll", EntryPoint = "GetWindowTextW")] private static partial int GetWindowText(nint hwnd, char* text, int max);
    [LibraryImport("user32.dll")] private static partial uint GetWindowThreadProcessId(nint hwnd, out uint pid);

    /// <summary>Title and process id of every visible top-level window that has a title. Never blocks on the owning process.</summary>
    public static List<(string Title, uint Pid)> Windows()
    {
        var list = new List<(string, uint)>();
        var buf = stackalloc char[512];
        for (nint h = 0; (h = FindWindowEx(0, h, 0, 0)) != 0;)
        {
            if (!IsWindowVisible(h)) continue;
            var n = GetWindowText(h, buf, 512);
            if (n <= 0) continue;
            GetWindowThreadProcessId(h, out var pid);
            list.Add((new string(buf, 0, n), pid));
        }
        return list;
    }
}
