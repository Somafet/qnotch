using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;

namespace QNotch.Modules.Ai;

/// <summary>Icons for exe, .lnk and shell:AppsFolder items through IShellItemImageFactory. Must run on an STA thread. Results are frozen.</summary>
internal static class ShellIcons
{
    const int Size = 64, SIIGBF_ICONONLY = 0x4;

    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }

    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out nint hbitmap);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHCreateItemFromParsingName(string path, nint pbc, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);

    public static ImageSource? Load(string target)
    {
        nint hbm = 0;
        IShellItemImageFactory? f = null;
        try
        {
            var iid = typeof(IShellItemImageFactory).GUID;
            if (SHCreateItemFromParsingName(target, 0, ref iid, out f) != 0) return null;
            if (f.GetImage(new SIZE { cx = Size, cy = Size }, SIIGBF_ICONONLY, out hbm) != 0 || hbm == 0) return null;
            var src = Imaging.CreateBitmapSourceFromHBitmap(hbm, 0, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        catch (Exception ex) { Log.Warn($"Icon for '{target}' failed", ex); return null; }
        finally
        {
            if (hbm != 0) DeleteObject(hbm);
            if (f is not null) Marshal.ReleaseComObject(f);
        }
    }

    /// <summary>Runs <see cref="Load"/> on a short-lived STA thread.</summary>
    public static Task<ImageSource?> LoadAsync(string target)
    {
        var tcs = new TaskCompletionSource<ImageSource?>();
        var t = new Thread(() => tcs.SetResult(Load(target))) { IsBackground = true, Name = "AiIcon" };
        t.SetApartmentState(ApartmentState.STA);
        t.Start();
        return tcs.Task;
    }
}
