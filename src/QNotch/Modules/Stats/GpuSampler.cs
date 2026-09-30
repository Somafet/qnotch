using System.Diagnostics;
using System.Runtime.InteropServices;

namespace QNotch.Modules.Stats;

/// <summary>
/// GPU utilization from the "GPU Engine" performance counters through PDH (no extra package). 3D engine utilization is
/// summed per engine over all processes; the busiest engine wins. Gives up permanently after repeated failures.
/// </summary>
internal sealed unsafe class GpuSampler : IDisposable
{
    const string Path = @"\GPU Engine(*engtype_3D)\Utilization Percentage";
    nint _query, _counter;
    bool _dead, _primed;
    int _failures;

    /// <summary>Moving average of one Sample() call in ms; the stats module skips GPU at the slow cadence if this is high.</summary>
    public double AvgMs { get; private set; }
    public bool Available => !_dead;

    public GpuSampler()
    {
        try
        {
            if (Pdh.PdhOpenQueryW(null, 0, out _query) != 0 || Pdh.PdhAddEnglishCounterW(_query, Path, 0, out _counter) != 0) _dead = true;
        }
        catch { _dead = true; }
    }

    public int? Sample()
    {
        if (_dead) return null;
        var sw = Stopwatch.StartNew();
        try
        {
            if (Pdh.PdhCollectQueryData(_query) != 0) return Fail();
            if (!_primed) { _primed = true; return null; } // rate counters need two samples

            uint size = 0, count = 0;
            if (Pdh.PdhGetFormattedCounterArrayW(_counter, Pdh.PDH_FMT_DOUBLE | Pdh.PDH_FMT_NOCAP100, ref size, ref count, 0) != Pdh.PDH_MORE_DATA) return Fail();
            var buf = NativeMemory.Alloc(size);
            try
            {
                if (Pdh.PdhGetFormattedCounterArrayW(_counter, Pdh.PDH_FMT_DOUBLE | Pdh.PDH_FMT_NOCAP100, ref size, ref count, (nint)buf) != 0) return Fail();
                if (count == 0) return null;
                var perEngine = new Dictionary<string, double>();
                for (uint i = 0; i < count; i++)
                {
                    var item = (byte*)buf + i * 24; // PDH_FMT_COUNTERVALUE_ITEM_W: name ptr, status, double
                    var status = *(uint*)(item + 8);
                    if (status > 1) continue;
                    var name = Marshal.PtrToStringUni(*(nint*)item) ?? "";
                    var at = name.IndexOf("_luid_", StringComparison.Ordinal);
                    var key = at >= 0 ? name[at..] : name;
                    perEngine[key] = perEngine.GetValueOrDefault(key) + *(double*)(item + 16);
                }
                _failures = 0;
                return perEngine.Count == 0 ? null : (int)Math.Clamp(perEngine.Values.Max(), 0, 100);
            }
            finally { NativeMemory.Free(buf); }
        }
        catch { return Fail(); }
        finally
        {
            var ms = sw.Elapsed.TotalMilliseconds;
            AvgMs = AvgMs == 0 ? ms : AvgMs * 0.7 + ms * 0.3;
        }
    }

    int? Fail()
    {
        if (++_failures >= 5) _dead = true;
        return null;
    }

    public void Dispose()
    {
        if (_query != 0) { Pdh.PdhCloseQuery(_query); _query = 0; }
    }
}
