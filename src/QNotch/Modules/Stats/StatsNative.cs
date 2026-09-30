using System.Runtime.InteropServices;

namespace QNotch.Modules.Stats;

[StructLayout(LayoutKind.Sequential)]
internal struct MEMORYSTATUSEX
{
    public uint dwLength, dwMemoryLoad;
    public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
}

[StructLayout(LayoutKind.Sequential)]
internal struct SYSTEM_POWER_STATUS
{
    public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
    public uint BatteryLifeTime, BatteryFullLifeTime;
}

/// <summary>P/Invoke used only by the Stats module.</summary>
internal static partial class StatsNative
{
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);
    [LibraryImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [LibraryImport("iphlpapi.dll")] public static partial int GetIfTable2(out nint table);
    [LibraryImport("iphlpapi.dll")] public static partial void FreeMibTable(nint table);
}
