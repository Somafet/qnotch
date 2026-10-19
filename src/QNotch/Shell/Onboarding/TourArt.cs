using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Path = System.Windows.Shapes.Path;
using QNotch.Theme;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// The tour's hero illustrations, built from the notch's own pieces: the pill hanging from the top edge, the panel and Home cards, key caps.
/// No bitmaps. Every brush is a theme resource, so light and dark both work.
/// </summary>
internal static class TourArt
{
    static readonly FontFamily Mono = new("Cascadia Mono, Consolas");

    public static T Brush<T>(T el, DependencyProperty p, string key) where T : FrameworkElement { el.SetResourceReference(p, key); return el; }

    public static TextBlock Text(string text, double size, string brush = "TextPrimaryBrush", FontWeight? weight = null)
    {
        var t = new TextBlock { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return t;
    }

    public static TextBlock Glyph(string glyph, double size, string brush = "TextSecondaryBrush")
    {
        var g = UiKit.Glyph(glyph, size, brush);
        g.VerticalAlignment = VerticalAlignment.Center;
        return g;
    }

    /// <summary>The hero backdrop: a raised surface with a soft accent glow from the top edge, where the pill hangs like on a screen.</summary>
    public static Grid Backdrop(double height)
    {
        var g = new Grid { Height = height, ClipToBounds = true };
        g.SetResourceReference(Grid.BackgroundProperty, "SurfaceRaisedBrush");
        var accent = Color(Application.Current.FindResource("AccentBrush"), Colors.CornflowerBlue);
        var glow = new RadialGradientBrush
        {
            Center = new Point(0.5, 0), GradientOrigin = new Point(0.5, 0), RadiusX = 0.62, RadiusY = 1.05,
            GradientStops = { new(System.Windows.Media.Color.FromArgb(0x48, accent.R, accent.G, accent.B), 0), new(System.Windows.Media.Color.FromArgb(0x14, accent.R, accent.G, accent.B), 0.55), new(Colors.Transparent, 1) },
        };
        glow.Freeze();
        g.Children.Add(new Rectangle { Fill = glow, IsHitTestVisible = false });
        // A faint dot grid, like a desktop seen through frosted glass.
        var dot = Colors.White; // the tour is always dark
        var tile = new DrawingBrush(new GeometryDrawing(new SolidColorBrush(System.Windows.Media.Color.FromArgb(0x10, dot.R, dot.G, dot.B)), null, new EllipseGeometry(new Point(1, 1), 0.9, 0.9)))
        {
            TileMode = TileMode.Tile, Viewport = new Rect(0, 0, 18, 18), ViewportUnits = BrushMappingMode.Absolute, Viewbox = new Rect(0, 0, 18, 18), ViewboxUnits = BrushMappingMode.Absolute,
        };
        tile.Freeze();
        var fade = new LinearGradientBrush(Colors.Black, Colors.Transparent, 90);
        fade.Freeze();
        g.Children.Add(new Rectangle { Fill = tile, OpacityMask = fade, IsHitTestVisible = false });
        var line = new Border { Height = 1, VerticalAlignment = VerticalAlignment.Bottom };
        line.SetResourceReference(Border.BackgroundProperty, "StrokeBrush");
        g.Children.Add(line);
        return g;
    }

    /// <summary>The collapsed pill: black, square on top, rounded at the bottom, hanging from the top edge.</summary>
    public static Border Pill(UIElement content, double minWidth = 96)
    {
        var b = new Border
        {
            Height = 38, MinWidth = minWidth, CornerRadius = new CornerRadius(0, 0, 16, 16), BorderThickness = new Thickness(1, 0, 1, 1),
            Padding = new Thickness(16, 0, 18, 1), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Child = content,
        };
        b.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        b.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        return b;
    }

    /// <summary>The live-looking pill: now playing on the left; weather, CPU and the clock on the right.</summary>
    public static Border LivePill()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Segment(Glyphs.Music, "Midnight City", "AccentBrush", 18));
        row.Children.Add(Segment("", "14°", "WarningBrush", 12));
        row.Children.Add(Segment("", "12%", "TextSecondaryBrush", 12));
        row.Children.Add(Text("09:41", 12.5, weight: FontWeights.SemiBold));
        return Pill(row);
    }

    static StackPanel Segment(string glyph, string text, string glyphBrush, double gap)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, gap, 0) };
        var g = Glyph(glyph, 12.5, glyphBrush);
        g.Margin = new Thickness(0, 0, 6, 0);
        s.Children.Add(g);
        s.Children.Add(Text(text, 12.5, weight: FontWeights.SemiBold));
        return s;
    }

    /// <summary>The pill widened for a moment with one line, like a peek.</summary>
    public static Border PeekPill(string glyph, string text, string brush)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var g = Glyph(glyph, 14, brush);
        g.Margin = new Thickness(0, 0, 8, 0);
        row.Children.Add(g);
        row.Children.Add(Text(text, 13, weight: FontWeights.SemiBold));
        var pill = Pill(row, 300);
        pill.Padding = new Thickness(22, 0, 24, 1);
        return pill;
    }

    /// <summary>The peek "QNotch is ready" with a drawn check whose stroke can be animated (dash offset from <see cref="CheckLength"/> to 0).</summary>
    public static Border ReadyPill(out Path check)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        check = new Path
        {
            Data = Geometry.Parse("M1,7 L5.5,11.5 L14,2"), StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round, Width = 15, Height = 14, Margin = new Thickness(0, 0, 9, 0), VerticalAlignment = VerticalAlignment.Center,
            StrokeDashArray = [CheckLength, CheckLength],
        };
        check.SetResourceReference(Shape.StrokeProperty, "SuccessBrush");
        System.Windows.Automation.AutomationProperties.SetName(check, "Ready");
        row.Children.Add(check);
        row.Children.Add(Text("QNotch is ready", 13, weight: FontWeights.SemiBold));
        var pill = Pill(row, 300);
        pill.Padding = new Thickness(22, 0, 24, 1);
        return pill;
    }

    /// <summary>The check's stroke length in dash units (path length divided by the stroke thickness), with a little slack.</summary>
    public const double CheckLength = 10.5;

    /// <summary>The open panel with three Home cards, fading out toward the bottom as if it were still opening.</summary>
    /// <param name="cards">Receives the three cards, for the unfold animation.</param>
    public static Border MiniPanel(double width, double height, List<UIElement>? cards = null)
    {
        var grid = new Grid { Margin = new Thickness(14, 10, 14, 0) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition());

        // Header: profile, the tab strip with Home picked, the action glyphs.
        var header = new Grid { Margin = new Thickness(2, 0, 2, 10) };
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition());
        var profile = new StackPanel { Orientation = Orientation.Horizontal };
        var avatar = new Grid { Width = 22, Height = 22 };
        avatar.Children.Add(Brush(new Ellipse(), Shape.FillProperty, "AccentSoftBrush"));
        var initial = Text("Q", 10.5, "AccentBrush", FontWeights.SemiBold);
        initial.HorizontalAlignment = HorizontalAlignment.Center;
        avatar.Children.Add(initial);
        profile.Children.Add(avatar);
        var who = new StackPanel { Margin = new Thickness(7, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        who.Children.Add(Text("Good morning", 10.5, weight: FontWeights.SemiBold));
        who.Children.Add(Text("Monday, October 19", 9, "TextTertiaryBrush"));
        profile.Children.Add(who);
        header.Children.Add(profile);
        var tabs = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(2) };
        tabs.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        var tabRow = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (g, on) in new[] { (Glyphs.Home, true), ("", false), (Glyphs.Music, false), (Glyphs.Clipboard, false), (Glyphs.Folder, false) })
        {
            var t = new Border { Width = 28, Height = 20, CornerRadius = new CornerRadius(7), Child = Glyph(g, 10.5, on ? "AccentBrush" : "TextTertiaryBrush") };
            ((TextBlock)t.Child).HorizontalAlignment = HorizontalAlignment.Center;
            if (on) { t.SetResourceReference(Border.BackgroundProperty, "ControlHoverBrush"); }
            tabRow.Children.Add(t);
        }
        tabs.Child = tabRow;
        Grid.SetColumn(tabs, 1);
        header.Children.Add(tabs);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var g in new[] { Glyphs.Edit, Glyphs.Pin, Glyphs.Settings })
        {
            var a = Glyph(g, 10.5, "TextTertiaryBrush");
            a.Margin = new Thickness(9, 0, 0, 0);
            actions.Children.Add(a);
        }
        Grid.SetColumn(actions, 2);
        header.Children.Add(actions);
        grid.Children.Add(header);

        var row = new UniformGrid3();
        foreach (var card in new[] { SystemCard(), MediaCard(), WeatherCard("Berlin") })
        {
            row.Add(card);
            cards?.Add(card);
        }
        row.Grid.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetRow(row.Grid, 1);
        grid.Children.Add(row.Grid);

        var fade = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1), GradientStops = { new(Colors.Black, 0), new(Colors.Black, 0.55), new(System.Windows.Media.Color.FromArgb(0x00, 0, 0, 0), 1) } };
        fade.Freeze();
        var panel = new Border
        {
            Width = width, Height = height, CornerRadius = new CornerRadius(22), BorderThickness = new Thickness(1), Child = grid,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, OpacityMask = fade, ClipToBounds = true,
        };
        panel.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        panel.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        return panel;
    }

    /// <summary>Three equal columns with a gap, for mini cards.</summary>
    internal sealed class UniformGrid3
    {
        public Grid Grid { get; } = new();
        public UniformGrid3(int columns = 3, double gap = 8)
        {
            for (var i = 0; i < columns * 2 - 1; i++) Grid.ColumnDefinitions.Add(new ColumnDefinition { Width = i % 2 == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(gap) });
        }
        public void Add(UIElement e)
        {
            Grid.SetColumn(e, Grid.Children.Count * 2);
            Grid.Children.Add(e);
        }
    }

    /// <summary>A mini Home card: title on top, then the body.</summary>
    public static Border Card(string title, UIElement body, double height = 104)
    {
        var s = new Grid();
        s.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        s.RowDefinitions.Add(new RowDefinition());
        s.Children.Add(Text(title, 10, "TextTertiaryBrush", FontWeights.SemiBold));
        Grid.SetRow(body, 1);
        s.Children.Add(body);
        var b = new Border { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(1), Padding = new Thickness(11, 8, 11, 9), Height = height, Child = s };
        b.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        b.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        return b;
    }

    static Border SystemCard()
    {
        var rows = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        foreach (var (label, value, fill) in new[] { ("CPU", "12%", 0.12), ("RAM", "4.2 GB", 0.42), ("GPU", "31%", 0.31) })
        {
            var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
            g.Children.Add(Text(label, 9.5, "TextSecondaryBrush"));
            var track = new Grid { Height = 4, VerticalAlignment = VerticalAlignment.Center };
            track.Children.Add(Brush(new Border { CornerRadius = new CornerRadius(2) }, Border.BackgroundProperty, "ControlHoverBrush"));
            var bar = Brush(new Border { CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left }, Border.BackgroundProperty, "AccentBrush");
            track.SizeChanged += (_, e) => bar.Width = Math.Max(4, e.NewSize.Width * fill);
            track.Children.Add(bar);
            Grid.SetColumn(track, 1);
            g.Children.Add(track);
            var v = Text(value, 9.5, weight: FontWeights.SemiBold);
            v.HorizontalAlignment = HorizontalAlignment.Right;
            Grid.SetColumn(v, 2);
            g.Children.Add(v);
            rows.Children.Add(g);
        }
        return Card("System", rows);
    }

    static Border MediaCard()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var accent = Color(Application.Current.FindResource("AccentBrush"), Colors.CornflowerBlue);
        var art = new LinearGradientBrush(accent, System.Windows.Media.Color.FromRgb(0xC2, 0x4D, 0xD6), 45);
        art.Freeze();
        var cover = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(8), Background = art, Child = Glyph(Glyphs.Music, 16, "OnAccentBrush") };
        ((TextBlock)cover.Child).HorizontalAlignment = HorizontalAlignment.Center;
        row.Children.Add(cover);
        var text = new StackPanel { Margin = new Thickness(9, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Text("Midnight City", 11, weight: FontWeights.SemiBold));
        text.Children.Add(Text("M83", 9.5, "TextSecondaryBrush"));
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 5, 0, 0) };
        foreach (var g in new[] { Glyphs.Previous, Glyphs.Pause, Glyphs.Next })
        {
            var c = Glyph(g, 9.5, "TextSecondaryBrush");
            c.Margin = new Thickness(0, 0, 10, 0);
            controls.Children.Add(c);
        }
        text.Children.Add(controls);
        row.Children.Add(text);
        return Card("Now playing", row);
    }

    public static Border WeatherCard(string place, double height = 104)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(Glyph("", 26, "WarningBrush"));
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Text("14°", 20, weight: FontWeights.SemiBold));
        text.Children.Add(Text($"{place}, partly cloudy", 9.5, "TextSecondaryBrush"));
        row.Children.Add(text);
        return Card("Weather", row, height);
    }

    /// <param name="cells">Receives the graph cells, each with its diagonal (column plus row) in Tag, for the fill wave.</param>
    public static Border GithubCard(double height, List<Border>? cells = null)
    {
        // A small contribution graph: fixed pseudo-random levels, so every snapshot is the same.
        var accent = Color(Application.Current.FindResource("AccentBrush"), Colors.CornflowerBlue);
        var grid = new UniformGrid3(12, 3).Grid;
        grid.VerticalAlignment = VerticalAlignment.Center;
        grid.HorizontalAlignment = HorizontalAlignment.Left;
        grid.Margin = new Thickness(0, 6, 0, 5);
        for (var c = 0; c < 12; c++)
        {
            var col = new StackPanel();
            for (var r = 0; r < 4; r++)
            {
                var level = (c * 7 + r * 3 + c * r) % 5;
                var cell = new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(1.5), Margin = new Thickness(0, 0, 0, r == 3 ? 0 : 3), Tag = c + r };
                cells?.Add(cell);
                if (level == 0) cell.SetResourceReference(Border.BackgroundProperty, "ControlHoverBrush");
                else
                {
                    var b = new SolidColorBrush(System.Windows.Media.Color.FromArgb((byte)(60 + level * 48), accent.R, accent.G, accent.B));
                    b.Freeze();
                    cell.Background = b;
                }
                col.Children.Add(cell);
            }
            Grid.SetColumn(col, c * 2);
            grid.Children.Add(col);
        }
        var body = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        body.Children.Add(grid);
        body.Children.Add(Text("1,284 contributions", 9.5, "TextSecondaryBrush"));
        return Card("GitHub", body, height);
    }

    public static Border AgentsCard(double height)
    {
        var rows = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        foreach (var (name, state, brush) in new[] { ("api", "Needs you", "WarningBrush"), ("website", "Working", "AccentBrush") })
        {
            var g = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var dot = Brush(new Ellipse { Width = 7, Height = 7, Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center }, Shape.FillProperty, brush);
            g.Children.Add(dot);
            var n = Text(name, 10.5, weight: FontWeights.SemiBold);
            Grid.SetColumn(n, 1);
            g.Children.Add(n);
            var s = Text(state, 9.5, brush);
            Grid.SetColumn(s, 2);
            g.Children.Add(s);
            rows.Children.Add(g);
        }
        return Card("Agents", rows, height);
    }

    /// <summary>One key cap, with a deeper bottom edge. <paramref name="lit"/>: the accent outline when the shortcut was just pressed.</summary>
    public static Border KeyCap(string key, double size, bool lit)
    {
        var t = new TextBlock { Text = key, FontSize = size, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, lit ? "AccentBrush" : "TextPrimaryBrush");
        var cap = new Border
        {
            MinWidth = size * 2.6, Height = size * 2.6, CornerRadius = new CornerRadius(size * 0.55), BorderThickness = new Thickness(1, 1, 1, 3),
            Padding = new Thickness(size * 0.7, 0, size * 0.7, 0), Child = t, Margin = new Thickness(size * 0.25, 0, size * 0.25, 0),
        };
        cap.SetResourceReference(Border.BackgroundProperty, lit ? "AccentSoftBrush" : "CardBrush");
        cap.SetResourceReference(Border.BorderBrushProperty, lit ? "AccentBrush" : "StrokeStrongBrush");
        return cap;
    }

    /// <summary>Key caps for a gesture ("Ctrl+Alt+N"), or a muted line when there is none.</summary>
    public static FrameworkElement KeyCaps(string gesture, double size, bool lit)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        if (gesture.Length == 0) { row.Children.Add(Text("No shortcut", size, "TextTertiaryBrush")); return row; }
        var parts = gesture.EndsWith("++", StringComparison.Ordinal) ? gesture[..^2].Split('+').Append("+") : gesture.Split('+');
        foreach (var p in parts.Where(p => p.Length > 0)) row.Children.Add(KeyCap(KeyName(p), size, lit));
        System.Windows.Automation.AutomationProperties.SetName(row, gesture);
        return row;
    }

    static string KeyName(string k) => k switch
    {
        "Control" => "Ctrl", "Windows" => "Win", "OemPlus" => "+", "OemMinus" => "-", "OemComma" => ",", "OemPeriod" => ".",
        "Space" => "Space", "Return" or "Enter" => "Enter",
        _ when k.Length == 2 && k[0] == 'D' && char.IsDigit(k[1]) => k[1..],
        _ => k,
    };

    /// <summary>A pointer arrow, drawn (the icon font has none that reads well at this size).</summary>
    public static Path Pointer()
    {
        var p = new Path
        {
            Data = Geometry.Parse("M0,0 L0,17 L4.2,13 L7.2,19.6 L10,18.4 L7,11.9 L12.6,11.9 Z"), StrokeThickness = 1.2, StrokeLineJoin = PenLineJoin.Round,
            Width = 14, Height = 21, Stretch = Stretch.None,
        };
        p.SetResourceReference(Shape.FillProperty, "TextPrimaryBrush");
        p.SetResourceReference(Shape.StrokeProperty, "SurfaceBrush");
        return p;
    }

    static System.Windows.Media.Color Color(object res, System.Windows.Media.Color fallback) => res is SolidColorBrush b ? b.Color : fallback;
}
