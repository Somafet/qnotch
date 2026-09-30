using System.Runtime.InteropServices;
using QNotch.Interop;

namespace QNotch.Shell;

public sealed record MonitorInfo(nint Handle, RECT Bounds, bool IsPrimary, double Scale)
{
    public string Label(int index) => $"Display {index + 1}  ({Bounds.Width} x {Bounds.Height}){(IsPrimary ? "  primary" : "")}";
}

public static unsafe class Monitors
{
    /// <summary>All connected monitors, primary first. Bounds are full monitor rectangles (not work area) in physical pixels.</summary>
    public static List<MonitorInfo> List()
    {
        var list = new List<MonitorInfo>();
        var handle = GCHandle.Alloc(list);
        try { Native.EnumDisplayMonitors(0, 0, &Enum, GCHandle.ToIntPtr(handle)); }
        finally { handle.Free(); }
        return list.OrderByDescending(m => m.IsPrimary).ToList();
    }

    public static MonitorInfo Get(int index)
    {
        var all = List();
        return all.Count == 0 ? new MonitorInfo(0, default, true, 1) : all[index >= 0 && index < all.Count ? index : 0];
    }

    [UnmanagedCallersOnly]
    static int Enum(nint hMonitor, nint hdc, nint rect, nint data)
    {
        var list = (List<MonitorInfo>)GCHandle.FromIntPtr(data).Target!;
        var mi = new MONITORINFO { cbSize = (uint)sizeof(MONITORINFO) };
        if (Native.GetMonitorInfo(hMonitor, ref mi))
        {
            Native.GetDpiForMonitor(hMonitor, 0, out var dpi, out _);
            list.Add(new MonitorInfo(hMonitor, mi.rcMonitor, (mi.dwFlags & 1) != 0, dpi == 0 ? 1 : dpi / 96.0));
        }
        return 1;
    }
}
