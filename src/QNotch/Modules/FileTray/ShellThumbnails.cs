using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace QNotch.Modules.FileTray;

/// <summary>Shell thumbnails through IShellItemImageFactory. Call from an STA background thread only.</summary>
internal static class ShellThumbnails
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(SIZE size, int flags, out nint hbitmap);
    }

    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int Type, Width, Height, WidthBytes; public short Planes, BitsPixel; public nint Bits; }
    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public int Size, Width, Height; public short Planes, BitCount; public int Compression, SizeImage, XPels, YPels, ClrUsed, ClrImportant;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, nint pbc, ref Guid riid, out IShellItemImageFactory ppv);
    [DllImport("gdi32.dll")] static extern int GetObjectW(nint h, int cb, out BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(nint hdc, nint hbm, uint start, uint lines, byte[]? bits, ref BITMAPINFOHEADER bmi, uint usage);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint h);
    [DllImport("user32.dll")] static extern nint GetDC(nint hwnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint hwnd, nint hdc);

    /// <summary>Returns a frozen BitmapSource (thumbnail, or the file type icon when there is none), or null on failure.</summary>
    public static BitmapSource? Get(string path, int size)
    {
        nint hbm = 0;
        try
        {
            var iid = typeof(IShellItemImageFactory).GUID;
            SHCreateItemFromParsingName(path, 0, ref iid, out var factory);
            try
            {
                if (factory.GetImage(new SIZE { cx = size, cy = size }, 0, out hbm) != 0 || hbm == 0) return null;
            }
            finally { Marshal.ReleaseComObject(factory); }
            return ToBitmapSource(hbm);
        }
        catch { return null; }
        finally { if (hbm != 0) DeleteObject(hbm); }
    }

    static BitmapSource? ToBitmapSource(nint hbm)
    {
        if (GetObjectW(hbm, Marshal.SizeOf<BITMAP>(), out var bm) == 0 || bm.Width <= 0 || bm.Height <= 0) return null;
        var bmi = new BITMAPINFOHEADER { Size = Marshal.SizeOf<BITMAPINFOHEADER>(), Width = bm.Width, Height = -bm.Height, Planes = 1, BitCount = 32 };
        var buf = new byte[bm.Width * bm.Height * 4];
        var dc = GetDC(0);
        try { if (GetDIBits(dc, hbm, 0, (uint)bm.Height, buf, ref bmi, 0) == 0) return null; }
        finally { ReleaseDC(0, dc); }
        // Some providers return 32 bpp without an alpha channel: treat that as opaque.
        var hasAlpha = false;
        for (var i = 3; i < buf.Length; i += 4) if (buf[i] != 0) { hasAlpha = true; break; }
        if (!hasAlpha) for (var i = 3; i < buf.Length; i += 4) buf[i] = 255;
        var bs = BitmapSource.Create(bm.Width, bm.Height, 96, 96, PixelFormats.Bgra32, null, buf, bm.Width * 4);
        bs.Freeze();
        return bs;
    }
}
