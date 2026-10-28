using System.Runtime.InteropServices;

namespace QNotch.Modules.Devices;

static partial class DevicesNative
{
    static readonly Guid DownloadsId = new("374DE290-123F-4565-9164-39C4925E467B");
    [LibraryImport("shell32.dll")] private static partial int SHGetKnownFolderPath(in Guid id, uint flags, nint token, out nint path);
    public static string Inbox()
    {
        string? downloads = null;
        var hr = SHGetKnownFolderPath(DownloadsId, 0, 0, out var path);
        try { if (hr == 0) downloads = Marshal.PtrToStringUni(path); }
        finally { Marshal.FreeCoTaskMem(path); }
        return Path.Combine(downloads ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"), "QNotch", "Devices");
    }
}
