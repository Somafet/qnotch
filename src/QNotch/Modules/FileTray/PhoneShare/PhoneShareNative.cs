using System.Runtime.InteropServices;

namespace QNotch.Modules.FileTray;

static partial class PhoneShareNative
{
    static readonly Guid FolderDownloads = new("374DE290-123F-4565-9164-39C4925E467B");

    [LibraryImport("shell32.dll")] private static partial int SHGetKnownFolderPath(in Guid id, uint flags, nint token, out nint path);

    /// <summary>The user's Downloads folder (it may have been moved to another drive), or the default location under the profile.</summary>
    public static string DownloadsFolder()
    {
        try
        {
            var hr = SHGetKnownFolderPath(FolderDownloads, 0, 0, out var p);
            try { if (hr == 0 && Marshal.PtrToStringUni(p) is { Length: > 0 } s) return s; }
            finally { Marshal.FreeCoTaskMem(p); } // freed even on failure, per the documentation
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException) { }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
    }
}
