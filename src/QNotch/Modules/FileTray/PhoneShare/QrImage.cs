using System.Windows;
using System.Windows.Media;

namespace QNotch.Modules.FileTray;

/// <summary>
/// Renders a QR matrix as a frozen vector image: dark modules on white with the standard four-module quiet zone. Always dark on light,
/// whatever the theme, since many scanners cannot read inverted codes. Show it with <c>RenderOptions.EdgeMode="Aliased"</c> for crisp edges.
/// </summary>
public static class QrImage
{
    const int Quiet = 4;

    public static DrawingImage Create(bool[,] modules)
    {
        var n = modules.GetLength(0);
        var full = n + Quiet * 2;
        var geo = new StreamGeometry();
        using (var g = geo.Open())
        {
            // One rectangle per horizontal run keeps the figure count low.
            for (var y = 0; y < n; y++)
                for (var x = 0; x < n; x++)
                {
                    if (!modules[y, x]) continue;
                    var start = x;
                    while (x + 1 < n && modules[y, x + 1]) x++;
                    double l = start + Quiet, r = x + 1 + Quiet, t = y + Quiet, b = y + 1 + Quiet;
                    g.BeginFigure(new Point(l, t), true, true);
                    g.PolyLineTo([new Point(r, t), new Point(r, b), new Point(l, b)], false, false);
                }
        }
        geo.Freeze();
        var group = new DrawingGroup();
        group.Children.Add(new GeometryDrawing(Brushes.White, null, new RectangleGeometry(new Rect(0, 0, full, full))));
        group.Children.Add(new GeometryDrawing(Brushes.Black, null, geo));
        var img = new DrawingImage(group);
        img.Freeze();
        return img;
    }
}
