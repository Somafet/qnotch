using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>The brand mark (dark rounded square, white notch pill, accent dot) drawn at runtime for window icons, About and the
/// tray, where the dot can change color to show state. The same mark is baked into Assets/AppIcon.ico for the exe.</summary>
public static unsafe class AppIcon
{
    public static BitmapSource Render(int size, Color? tint = null)
    {
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            double s = size, k = s / 32;
            // Pill at 7,9 / 18x7 of 32; snapped to whole pixels at small sizes so its edges stay sharp.
            double x0 = 7 * k, y0 = 9 * k, x1 = 25 * k, y1 = 16 * k;
            if (size <= 48)
            {
                x0 = Math.Round(x0); x1 = Math.Round(x1); y0 = Math.Round(y0); y1 = Math.Max(Math.Round(y1), y0 + 3);
            }
            var h = y1 - y0;
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(0x0B, 0x0B, 0x0D)), null, new Rect(0, 0, s, s), 8 * k, 8 * k);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(0xF4, 0xF4, 0xF7)), null, new Rect(x0, y0, x1 - x0, h), h / 2, h / 2);
            dc.DrawEllipse(new SolidColorBrush(tint ?? Color.FromRgb(0x5B, 0x9D, 0xFF)), null, new Point(x1 - h / 2, (y0 + y1) / 2), Math.Max(1, 1.6 * k), Math.Max(1, 1.6 * k));
        }
        var rtb = new RenderTargetBitmap(size, size, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);
        rtb.Freeze();
        return rtb;
    }

    /// <summary>Creates an HICON (caller owns it: DestroyIcon).</summary>
    public static nint CreateHIcon(int size = 32, Color? tint = null)
    {
        var bmp = Render(size, tint);
        var px = new byte[size * size * 4];
        bmp.CopyPixels(px, size * 4, 0);
        // Pbgra32 to straight alpha.
        for (var i = 0; i < px.Length; i += 4)
        {
            var a = px[i + 3];
            if (a is 0 or 255) continue;
            px[i] = (byte)Math.Min(255, px[i] * 255 / a);
            px[i + 1] = (byte)Math.Min(255, px[i + 1] * 255 / a);
            px[i + 2] = (byte)Math.Min(255, px[i + 2] * 255 / a);
        }
        var mask = new byte[size * size / 8];
        nint color, maskBmp;
        fixed (byte* p = px) color = Native.CreateBitmap(size, size, 1, 32, p);
        fixed (byte* m = mask) maskBmp = Native.CreateBitmap(size, size, 1, 1, m);
        var ii = new ICONINFO { fIcon = 1, hbmColor = color, hbmMask = maskBmp };
        var icon = Native.CreateIconIndirect(ref ii);
        Native.DeleteObject(color);
        Native.DeleteObject(maskBmp);
        return icon;
    }
}
