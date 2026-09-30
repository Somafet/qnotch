using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using QNotch.Theme;

namespace QNotch.Modules.Stats;

/// <summary>Pill and game bar views of the Stats module. Built in code: no XAML parse on the cold start path. Minimum widths keep changing digits from resizing the host.</summary>
internal static class StatsSegments
{
    // ---------- pill: CPU, RAM, network, battery, clock in one element ----------

    public static FrameworkElement Pill(StatsState st)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(Pair("CPU", st, nameof(StatsState.CpuText), 50, small: true, gap: true));
        p.Children.Add(Pair("RAM", st, nameof(StatsState.RamText), 98, small: true, gap: true));
        p.Children.Add(Net(st, 116, gap: true));
        p.Children.Add(Battery(st, 13, gap: true));
        p.Children.Add(Clock(st, 13, 36));
        return p;
    }

    // ---------- game bar: one element per segment (the shell sets margins and inherits the bar font size) ----------

    public static FrameworkElement GameCpu(StatsState st) => Pair("CPU", st, nameof(StatsState.CpuText), 44);

    /// <summary>Collapsed while the GPU counter is unusable. <paramref name="wanted"/> follows the visibility so the sampler queries the GPU only while it shows.</summary>
    public static FrameworkElement GameGpu(StatsState st, Action<bool> wanted)
    {
        var t = Pair("GPU", st, nameof(StatsState.GpuText), 44);
        UiKit.BindVisible(t, st, nameof(StatsState.GpuAvailable));
        t.IsVisibleChanged += (_, e) => wanted((bool)e.NewValue);
        return t;
    }

    public static FrameworkElement GameRam(StatsState st) => Pair("RAM", st, nameof(StatsState.RamText), 96);
    public static FrameworkElement GameNet(StatsState st) => Net(st, 124);
    public static FrameworkElement GameBattery(StatsState st) => Battery(st, 12);
    public static FrameworkElement GameClock(StatsState st) => Clock(st, null, 34);

    // ---------- parts ----------

    static Run Tertiary(string text, bool label = false, double? size = null)
    {
        var r = new Run(text);
        if (label) r.FontWeight = FontWeights.SemiBold;
        if (size is { } s) r.FontSize = s;
        r.SetResourceReference(TextElement.ForegroundProperty, "TextTertiaryBrush");
        return r;
    }

    static Run Bound(StatsState st, string path) => UiKit.Bind(new Run(), Run.TextProperty, st, path);

    /// <summary>"CPU 12%": semibold tertiary label, then the bound value. <paramref name="small"/>: 10 pt label (game bar labels inherit the bar size).</summary>
    static TextBlock Pair(string label, StatsState st, string path, double minWidth, bool small = false, bool gap = false)
    {
        var t = new TextBlock { VerticalAlignment = VerticalAlignment.Center, MinWidth = minWidth };
        if (gap) t.Margin = new Thickness(0, 0, 12, 0);
        t.Inlines.Add(Tertiary(label, label: true, size: small ? 10 : null));
        t.Inlines.Add(new Run(" "));
        t.Inlines.Add(Bound(st, path));
        return t;
    }

    static TextBlock Net(StatsState st, double minWidth, bool gap = false)
    {
        var t = new TextBlock { VerticalAlignment = VerticalAlignment.Center, MinWidth = minWidth };
        if (gap) t.Margin = new Thickness(0, 0, 12, 0);
        t.Inlines.Add(Tertiary("↓"));
        t.Inlines.Add(Bound(st, nameof(StatsState.NetDownText)));
        t.Inlines.Add(new Run("  "));
        t.Inlines.Add(Tertiary("↑"));
        t.Inlines.Add(Bound(st, nameof(StatsState.NetUpText)));
        return t;
    }

    /// <summary>Battery glyph and percentage; collapsed without a battery.</summary>
    static FrameworkElement Battery(StatsState st, double glyphSize, bool gap = false)
    {
        var glyph = new TextBlock { Style = (Style)Application.Current.FindResource("Glyph"), FontSize = glyphSize, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) };
        UiKit.Bind(glyph, TextBlock.TextProperty, st, nameof(StatsState.BatteryGlyph));
        var text = new TextBlock { MinWidth = 28, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(text, TextBlock.TextProperty, st, nameof(StatsState.BatteryText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (gap) p.Margin = new Thickness(0, 0, 12, 0);
        p.Children.Add(glyph);
        p.Children.Add(text);
        return UiKit.BindVisible(p, st, nameof(StatsState.HasBattery));
    }

    static TextBlock Clock(StatsState st, double? size, double minWidth)
    {
        var t = new TextBlock { FontWeight = FontWeights.SemiBold, MinWidth = minWidth, VerticalAlignment = VerticalAlignment.Center };
        if (size is { } s) t.FontSize = s;
        return UiKit.Bind(t, TextBlock.TextProperty, st, nameof(StatsState.Clock));
    }
}
