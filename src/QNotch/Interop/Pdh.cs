using System.Runtime.InteropServices;

namespace QNotch.Interop;

/// <summary>Performance Data Helper: used by the stats module for the "GPU Engine" counters.</summary>
internal static unsafe partial class Pdh
{
    public const uint PDH_FMT_DOUBLE = 0x200, PDH_FMT_NOCAP100 = 0x8000, PDH_MORE_DATA = 0x800007D2;

    [LibraryImport("pdh.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint PdhOpenQueryW(string? source, nint userData, out nint query);
    [LibraryImport("pdh.dll", StringMarshalling = StringMarshalling.Utf16)]
    public static partial uint PdhAddEnglishCounterW(nint query, string path, nint userData, out nint counter);
    [LibraryImport("pdh.dll")] public static partial uint PdhCollectQueryData(nint query);
    [LibraryImport("pdh.dll")] public static partial uint PdhGetFormattedCounterArrayW(nint counter, uint format, ref uint bufferSize, ref uint itemCount, nint buffer);
    [LibraryImport("pdh.dll")] public static partial uint PdhCloseQuery(nint query);
}
