using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Interop;

namespace QNotch.Shell;

/// <summary>The app icon (a notch pill) drawn at startup: no .ico asset to ship.</summary>
public static unsafe class AppIcon
{
    public static BitmapSource Render(int size, Color? tint = null)
    {
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            var s = size;
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromRgb(0x14, 0x14, 0x18)), null, new Rect(0, 0, s, s), s * 0.22, s * 0.22);
            var pill = new Rect(s * 0.14, s * 0.2, s * 0.72, s * 0.3);
            var geo = new PathGeometry();
            var r = s * 0.15;
            var fig = new PathFigure { StartPoint = new Point(pill.Left, pill.Top), IsClosed = true };
            fig.Segments.Add(new LineSegment(new Point(pill.Right, pill.Top), true));
            fig.Segments.Add(new LineSegment(new Point(pill.Right, pill.Bottom - r), true));
            fig.Segments.Add(new ArcSegment(new Point(pill.Right - r, pill.Bottom), new Size(r, r), 0, false, SweepDirection.Clockwise, true));
            fig.Segments.Add(new LineSegment(new Point(pill.Left + r, pill.Bottom), true));
            fig.Segments.Add(new ArcSegment(new Point(pill.Left, pill.Bottom - r), new Size(r, r), 0, false, SweepDirection.Clockwise, true));
            geo.Figures.Add(fig);
            dc.DrawGeometry(new SolidColorBrush(tint ?? Color.FromRgb(0x5B, 0x9D, 0xFF)), null, geo);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(0x55, 255, 255, 255)), null, new Rect(s * 0.14, s * 0.62, s * 0.72, s * 0.1), s * 0.05, s * 0.05);
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(0x33, 255, 255, 255)), null, new Rect(s * 0.14, s * 0.78, s * 0.45, s * 0.08), s * 0.04, s * 0.04);
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
