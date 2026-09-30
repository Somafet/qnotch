using System.Diagnostics;
using QNotch.Interop;

namespace QNotch.Modules.Stats;

/// <summary>One immutable sample, posted from the thread pool. Null means "unavailable" (never a fake zero).</summary>
public sealed record StatsSample(int Cpu, int? Gpu, long RamUsed, long RamTotal, double? NetDown, double? NetUp,
    bool HasBattery, int? BatteryPercent, bool Charging);

/// <summary>Win32 sampling: GetSystemTimes, GlobalMemoryStatusEx, GetIfTable2, GetSystemPowerStatus. Thread-pool only, never on the UI thread.</summary>
internal sealed unsafe class SystemSampler
{
    const int RowSize = 1352; // sizeof(MIB_IF_ROW2)
    ulong _idle, _kernel, _user, _rx, _tx;
    long _netStamp;
    int _lastCpu;
    bool _netOk;

    public SystemSampler()
    {
        Native.GetSystemTimes(out _idle, out _kernel, out _user);
        _netOk = ReadNet(out _rx, out _tx);
        _netStamp = Stopwatch.GetTimestamp();
    }

    public StatsSample Sample(int? gpu)
    {
        // CPU: kernel time includes idle time.
        if (Native.GetSystemTimes(out var i, out var k, out var u))
        {
            var total = (k - _kernel) + (u - _user);
            if (total > 0) _lastCpu = (int)Math.Clamp((total - (i - _idle)) * 100.0 / total, 0, 100);
            (_idle, _kernel, _user) = (i, k, u);
        }

        var mem = new MEMORYSTATUSEX { dwLength = (uint)sizeof(MEMORYSTATUSEX) };
        Native.GlobalMemoryStatusEx(ref mem);

        double? down = null, up = null;
        var ok = ReadNet(out var rx, out var tx);
        var now = Stopwatch.GetTimestamp();
        if (ok && _netOk)
        {
            var dt = (now - _netStamp) / (double)Stopwatch.Frequency;
            if (dt > 0.05)
            {
                down = rx >= _rx ? (rx - _rx) / dt : 0;
                up = tx >= _tx ? (tx - _tx) / dt : 0;
            }
        }
        (_rx, _tx, _netStamp, _netOk) = (rx, tx, now, ok);

        var hasBattery = false; int? pct = null; var charging = false;
        if (Native.GetSystemPowerStatus(out var ps))
        {
            hasBattery = ps.BatteryFlag != 128 && ps.BatteryFlag != 255;
            if (hasBattery && ps.BatteryLifePercent <= 100) pct = ps.BatteryLifePercent;
            charging = hasBattery && (ps.BatteryFlag & 8) != 0;
        }
        return new StatsSample(_lastCpu, gpu, (long)(mem.ullTotalPhys - mem.ullAvailPhys), (long)mem.ullTotalPhys, down, up, hasBattery, pct, charging);
    }

    /// <summary>Sums octet counters of up, hardware (physical) interfaces. Skips loopback, tunnels and virtual adapters.</summary>
    static bool ReadNet(out ulong rx, out ulong tx)
    {
        rx = tx = 0;
        if (Native.GetIfTable2(out var table) != 0 || table == 0) return false;
        try
        {
            var n = *(uint*)table;
            var rows = (byte*)table + 8;
            for (uint i = 0; i < n; i++)
            {
                var r = rows + i * RowSize;
                var type = *(uint*)(r + 1128);
                var hardware = (r[1152] & 1) != 0;
                var oper = *(int*)(r + 1156);
                if (!hardware || oper != 1 || type == 24) continue;
                rx += *(ulong*)(r + 1208);
                tx += *(ulong*)(r + 1280);
            }
            return true;
        }
        finally { Native.FreeMibTable(table); }
    }
}
