using System.Runtime.InteropServices;

namespace QNotch.Modules.Stats;

/// <summary>
/// GPU temperature from the graphics kernel (D3DKMT adapter perf data, the source Task Manager uses; no admin rights).
/// Adapters are opened once; the hottest one wins. Adapters that report 0 (most integrated GPUs) are ignored.
/// </summary>
internal sealed unsafe partial class GpuTemp : IDisposable
{
    const int MaxAdapters = 16, AdapterInfoSize = 20; // D3DKMT_ADAPTERINFO: handle, LUID, sources, precise present flag
    const int KMTQAITYPE_ADAPTERPERFDATA = 62, PerfDataSize = 64, TemperatureOffset = 56;

    [StructLayout(LayoutKind.Sequential)] struct EnumAdapters2 { public uint NumAdapters; public byte* Adapters; }
    [StructLayout(LayoutKind.Sequential)] struct QueryAdapterInfo { public uint Adapter; public int Type; public void* Data; public uint Size; }

    [LibraryImport("gdi32.dll")] private static partial int D3DKMTEnumAdapters2(ref EnumAdapters2 e);
    [LibraryImport("gdi32.dll")] private static partial int D3DKMTQueryAdapterInfo(ref QueryAdapterInfo q);
    [LibraryImport("gdi32.dll")] private static partial int D3DKMTCloseAdapter(ref uint adapter);

    readonly uint[] _adapters = [];

    public GpuTemp()
    {
        try
        {
            var buf = stackalloc byte[MaxAdapters * AdapterInfoSize];
            var e = new EnumAdapters2 { NumAdapters = MaxAdapters, Adapters = buf };
            if (D3DKMTEnumAdapters2(ref e) != 0) return;
            _adapters = new uint[e.NumAdapters];
            for (var i = 0; i < _adapters.Length; i++) _adapters[i] = *(uint*)(buf + i * AdapterInfoSize);
        }
        catch { }
    }

    /// <summary>Degrees Celsius, or null when no adapter reports a temperature.</summary>
    public int? Sample()
    {
        uint max = 0;
        var data = stackalloc byte[PerfDataSize];
        foreach (var a in _adapters)
        {
            new Span<byte>(data, PerfDataSize).Clear(); // PhysicalAdapterIndex 0
            var q = new QueryAdapterInfo { Adapter = a, Type = KMTQAITYPE_ADAPTERPERFDATA, Data = data, Size = PerfDataSize };
            if (D3DKMTQueryAdapterInfo(ref q) == 0) max = Math.Max(max, *(uint*)(data + TemperatureOffset)); // deci-Celsius
        }
        return max == 0 ? null : (int)Math.Round(max / 10.0);
    }

    public void Dispose()
    {
        for (var i = 0; i < _adapters.Length; i++) D3DKMTCloseAdapter(ref _adapters[i]);
    }
}
