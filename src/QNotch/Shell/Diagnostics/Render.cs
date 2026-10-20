using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace QNotch.Shell.Diagnostics;

/// <summary>Writes a view to PNG at 2x over a flat background, with its <see cref="Outline"/> next to it as <c>.txt</c>.</summary>
internal static class Render
{
    /// <summary>The whole of <paramref name="el"/> over its <c>WindowBrush</c>.</summary>
    public static void Save(FrameworkElement el, string path) =>
        Save(el, new Rect(0, 0, el.ActualWidth, el.ActualHeight), path, (Brush)el.FindResource("WindowBrush"));

    /// <summary>Renders <paramref name="crop"/> of <paramref name="el"/> (DIPs) over <paramref name="background"/> at 2x.</summary>
    public static void Save(FrameworkElement el, Rect crop, string path, Brush background)
    {
        el.UpdateLayout();
        // Off-screen the window has no monitor, so on a scaled display it is laid out wider than WinW: the notch stays centered.
        if (el.ActualWidth > crop.Width) crop.X += (el.ActualWidth - crop.Width) / 2;
        int W(double v) => (int)Math.Ceiling(v * 2);
        var full = new RenderTargetBitmap(W(el.ActualWidth), W(el.ActualHeight), 192, 192, PixelFormats.Pbgra32);
        full.Render(el);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(background, null, new Rect(0, 0, crop.Width, crop.Height));
            dc.DrawImage(full, new Rect(-crop.X, -crop.Y, el.ActualWidth, el.ActualHeight));
        }
        Write(dv, crop.Size, path);
        File.WriteAllText(Path.ChangeExtension(path, ".txt"), Outline.Of(el, crop));
    }

    /// <summary>A part of a window (a Home card) on its own over <paramref name="background"/>, wherever it sits or is scrolled to.</summary>
    public static void SavePart(FrameworkElement el, string path, Brush background)
    {
        el.UpdateLayout();
        var size = new Rect(0, 0, el.ActualWidth, el.ActualHeight);
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            dc.DrawRectangle(background, null, size);
            // The brush draws the element at its offset in the parent (scrolling aside): the view box starts there.
            var at = VisualTreeHelper.GetOffset(el);
            var box = new Rect(at.X, at.Y, size.Width, size.Height);
            dc.DrawRectangle(new VisualBrush(el) { Viewbox = box, ViewboxUnits = BrushMappingMode.Absolute, Stretch = Stretch.Fill }, null, size);
        }
        Write(dv, size.Size, path);
        File.WriteAllText(Path.ChangeExtension(path, ".txt"), Outline.Of(el));
    }

    static void Write(Visual v, Size size, string path)
    {
        var bmp = new RenderTargetBitmap((int)Math.Ceiling(size.Width * 2), (int)Math.Ceiling(size.Height * 2), 192, 192, PixelFormats.Pbgra32);
        bmp.Render(v);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
    }
}
