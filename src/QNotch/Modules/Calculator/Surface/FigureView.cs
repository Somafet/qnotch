using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Media;
using Calc.Core;

namespace Calc.Windows;

/// <summary>One inline plot or chart. WPF retains what OnRender draws, so it runs once per value, size or theme change and moving the element never redraws it.
/// All colour comes from theme resources; there is no timer, animation or background work.</summary>
internal sealed class FigureView : FrameworkElement
{
    private static readonly Typeface Face = new(new FontFamily("Segoe UI Variable Text, Segoe UI"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    private const double LabelSize = 11, LabelRow = 16, ValueRow = 16, MaxBar = 24, MaxSlot = 72, BarRadius = 4;
    private const int MaxSlices = 8, LegendRows = 7;
    public static readonly DependencyProperty InkProperty = Theme(nameof(Ink)), AccentProperty = Theme(nameof(Accent)), MutedProperty = Theme(nameof(Muted)), RuleProperty = Theme(nameof(Rule));
    private static DependencyProperty Theme(string name) => DependencyProperty.Register(name, typeof(Brush), typeof(FigureView), new FrameworkPropertyMetadata(Brushes.Transparent, FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Ink { get => (Brush)GetValue(InkProperty); set => SetValue(InkProperty, value); }
    public Brush Accent { get => (Brush)GetValue(AccentProperty); set => SetValue(AccentProperty, value); }
    public Brush Muted { get => (Brush)GetValue(MutedProperty); set => SetValue(MutedProperty, value); }
    public Brush Rule { get => (Brush)GetValue(RuleProperty); set => SetValue(RuleProperty, value); }
    private SheetValue? value;
    internal int RenderCount { get; private set; }
    internal SheetValue? Value => value;
    internal FigureView()
    {
        SetResourceReference(InkProperty, "AccentBrush"); SetResourceReference(AccentProperty, "WarningBrush");
        SetResourceReference(MutedProperty, "TextSecondaryBrush"); SetResourceReference(RuleProperty, "StrokeBrush");
    }
    internal void Show(SheetValue next)
    {
        if (value == next) return;
        value = next; InvalidateVisual();
        var plot = next.Kind == SheetValueKind.Plot;
        AutomationProperties.SetName(this, plot ? next.Plot.Description : next.Chart.Description);
        AutomationProperties.SetHelpText(this, plot ? next.Plot.Details : next.Chart.Details);
    }
    private sealed class Peer(FigureView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Image;
        protected override string GetClassNameCore() => "Figure";
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);
    private FormattedText Text(string text, Brush brush, double limit = double.PositiveInfinity)
    {
        var formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, LabelSize, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);
        if (!double.IsInfinity(limit)) { formatted.MaxTextWidth = Math.Max(1, limit); formatted.MaxLineCount = 1; formatted.Trimming = TextTrimming.CharacterEllipsis; }
        return formatted;
    }
    protected override void OnRender(DrawingContext context)
    {
        RenderCount++;
        if (value is not { } shown || ActualWidth < 80 || ActualHeight < 40) return;
        if (shown.Kind == SheetValueKind.Plot) DrawPlot(context, shown.Plot);
        else if (shown.Chart.Kind == ChartKind.Bar) DrawBars(context, shown.Chart);
        else if (shown.Chart.Kind == ChartKind.Pie) DrawPie(context, shown.Chart);
        else DrawTrend(context, shown.Chart);
    }
    // A plot area with its extremes in muted text: value range at the left, position range underneath.
    private Rect Frame(DrawingContext context, string high, string low, string start, string end)
    {
        var top = Text(high, Muted); var bottom = Text(low, Muted);
        var left = Math.Ceiling(Math.Max(top.Width, bottom.Width)) + 8;
        var area = new Rect(left, 4, Math.Max(1, ActualWidth - left - 2), ActualHeight - LabelRow - 4);
        context.DrawText(top, new(left - 8 - top.Width, area.Top - 2));
        context.DrawText(bottom, new(left - 8 - bottom.Width, area.Bottom - bottom.Height + 2));
        var first = Text(start, Muted, area.Width / 2 - 4); var last = Text(end, Muted, area.Width / 2 - 4);
        context.DrawText(first, new(area.Left, area.Bottom + 3));
        context.DrawText(last, new(area.Right - Math.Min(last.Width, area.Width / 2 - 4), area.Bottom + 3));
        return area;
    }
    private Pen Line() => new(Ink, 2) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
    private void DrawPlot(DrawingContext context, PlotValue plot)
    {
        var area = Frame(context, PlotValue.Number(plot.YUpper), PlotValue.Number(plot.YLower), PlotValue.Number(plot.Lower), PlotValue.Number(plot.Upper));
        double X(double x) => area.Left + (x - plot.Lower) / (plot.Upper - plot.Lower) * area.Width;
        double Y(double y) => area.Bottom - (y - plot.YLower) / (plot.YUpper - plot.YLower) * area.Height;
        if (plot.YLower < 0 && plot.YUpper > 0) context.DrawLine(new Pen(Rule, 1), new(area.Left, Math.Round(Y(0)) + .5), new(area.Right, Math.Round(Y(0)) + .5));
        var (upper, lower) = (area.Top - 2, area.Bottom + 2);
        var curve = new StreamGeometry(); var pen = Line();
        using (var sink = curve.Open())
            for (var segment = 0; segment < plot.SegmentStarts.Count; segment++)
            {
                var first = plot.SegmentStarts[segment];
                var last = (segment + 1 < plot.SegmentStarts.Count ? plot.SegmentStarts[segment + 1] : plot.X.Count) - 1;
                if (first == last)
                {
                    if (Y(plot.Y[first]) is var dot && dot >= upper && dot <= lower) context.DrawEllipse(Ink, null, new(X(plot.X[first]), dot), 1.5, 1.5);
                    continue;
                }
                var open = false; var reached = new Point();
                for (var i = first + 1; i <= last; i++)
                {
                    Point a = new(X(plot.X[i - 1]), Y(plot.Y[i - 1])), b = new(X(plot.X[i]), Y(plot.Y[i]));
                    // Cut each step at the band, so a pole's huge values never reach the renderer and the visible slope stays true.
                    if (a.Y < upper && b.Y < upper || a.Y > lower && b.Y > lower) { open = false; continue; }
                    Point Cut(Point from, Point to) => from.Y >= upper && from.Y <= lower ? from : new(from.X + (to.X - from.X) * ((from.Y < upper ? upper : lower) - from.Y) / (to.Y - from.Y), from.Y < upper ? upper : lower);
                    var (start, end) = (Cut(a, b), Cut(b, a));
                    if (!open || start != reached) { sink.BeginFigure(start, false, false); open = true; }
                    sink.LineTo(end, true, true); reached = end;
                }
            }
        curve.Freeze(); context.DrawGeometry(null, pen, curve);
    }
    private void DrawTrend(DrawingContext context, ChartValue chart)
    {
        var items = chart.Items; var low = items.MinBy(item => item.Magnitude)!; var high = items.MaxBy(item => item.Magnitude)!;
        var area = Frame(context, high.Display, low.Display, items[0].Label, items[^1].Label);
        var span = high.Magnitude > low.Magnitude ? high.Magnitude - low.Magnitude : 1;
        area = new(area.Left, area.Top, Math.Max(1, area.Width - 6), area.Height);
        Point At(int i) => new(area.Left + i * area.Width / (items.Count - 1), area.Bottom - (items[i].Magnitude - low.Magnitude) / span * area.Height);
        var line = new StreamGeometry();
        using (var sink = line.Open())
        {
            sink.BeginFigure(At(0), false, false);
            for (var i = 1; i < items.Count; i++) sink.LineTo(At(i), true, true);
        }
        line.Freeze(); context.DrawGeometry(null, Line(), line);
        context.DrawEllipse(Ink, null, At(items.Count - 1), 3.5, 3.5);
    }
    private void DrawBars(DrawingContext context, ChartValue chart)
    {
        var items = chart.Items; var low = Math.Min(0, items.Min(item => item.Magnitude)); var high = Math.Max(0, items.Max(item => item.Magnitude));
        var span = high > low ? high - low : 1;
        var slot = Math.Min(ActualWidth / items.Count, MaxSlot); var bar = Math.Clamp(slot * .6, 2, MaxBar);
        // Negative bars keep a value row below them too, so their amounts never meet the label row.
        var (top, bottom) = (ValueRow, ActualHeight - LabelRow - (low < 0 ? ValueRow : 0));
        var zero = Math.Round(bottom - (0 - low) / span * (bottom - top));
        var labelled = slot >= 28;
        for (var i = 0; i < items.Count; i++)
        {
            var center = slot * (i + .5); var height = Math.Abs(items[i].Magnitude) / span * (bottom - top);
            if (height >= .5) context.DrawGeometry(Ink, null, Bar(center - bar / 2, zero, bar, height, items[i].Magnitude >= 0));
            if (!labelled) continue;
            var name = Text(items[i].Label, Muted, slot - 4);
            context.DrawText(name, new(center - Math.Min(name.Width, slot - 4) / 2, ActualHeight - LabelRow + 3));
            var amount = Text(items[i].Display, Muted);
            if (amount.Width <= slot - 4)
                context.DrawText(amount, new(center - amount.Width / 2, items[i].Magnitude >= 0 ? zero - height - amount.Height - 1 : zero + height + 1));
        }
        if (!labelled)
        {
            // Too narrow for every label: the largest magnitude above, the first and last labels below.
            context.DrawText(Text(items.MaxBy(item => Math.Abs(item.Magnitude))!.Display, Muted, ActualWidth), new(0, 0));
            context.DrawText(Text(items[0].Label, Muted, ActualWidth / 2 - 4), new(0, ActualHeight - LabelRow + 3));
            var last = Text(items[^1].Label, Muted, ActualWidth / 2 - 4);
            context.DrawText(last, new(slot * items.Count - last.Width, ActualHeight - LabelRow + 3));
        }
        context.DrawLine(new Pen(Rule, 1), new(0, zero + .5), new(slot * items.Count, zero + .5));
    }
    // Rounded at the data end, square at the baseline.
    private static StreamGeometry Bar(double left, double zero, double width, double height, bool up)
    {
        var radius = Math.Min(BarRadius, Math.Min(width / 2, height)); var end = up ? zero - height : zero + height; var inner = up ? end + radius : end - radius;
        var sweep = up ? SweepDirection.Clockwise : SweepDirection.Counterclockwise;
        var shape = new StreamGeometry();
        using (var sink = shape.Open())
        {
            sink.BeginFigure(new(left, zero), true, true);
            sink.LineTo(new(left, inner), true, false);
            sink.ArcTo(new(left + radius, end), new(radius, radius), 0, false, sweep, true, false);
            sink.LineTo(new(left + width - radius, end), true, false);
            sink.ArcTo(new(left + width, inner), new(radius, radius), 0, false, sweep, true, false);
            sink.LineTo(new(left + width, zero), true, false);
        }
        shape.Freeze(); return shape;
    }
    private Brush Series(int index)
    {
        var source = (index % 3) switch { 0 => Ink, 1 => Accent, _ => Muted };
        var strength = (index / 3) switch { 0 => 1d, 1 => .55, _ => .3 };
        if (strength == 1) return source;
        var faded = source.CloneCurrentValue(); faded.Opacity = strength; faded.Freeze(); return faded;
    }
    private void DrawPie(DrawingContext context, ChartValue chart)
    {
        var total = chart.Items.Sum(item => item.Magnitude);
        // Beyond eight slices hues stop being distinguishable: the smallest fold into Other, in the legend as well as the pie.
        var slices = chart.Items.Select(item => (item.Label, item.Magnitude)).Where(slice => slice.Magnitude > 0).ToList();
        if (slices.Count > MaxSlices)
        {
            var kept = slices.OrderByDescending(slice => slice.Magnitude).Take(MaxSlices - 1).ToHashSet();
            var other = slices.Where(slice => !kept.Contains(slice)).Sum(slice => slice.Magnitude);
            slices = slices.Where(kept.Contains).Append((UiText.Current["other"], other)).ToList();
        }
        var radius = (ActualHeight - 4) / 2; var center = new Point(radius + 2, ActualHeight / 2); var angle = -Math.PI / 2;
        for (var i = 0; i < slices.Count; i++)
        {
            var sweep = slices[i].Magnitude / total * 2 * Math.PI; var middle = angle + sweep / 2;
            var fill = Series(i);
            if (slices.Count == 1) context.DrawEllipse(fill, null, center, radius, radius);
            else
            {
                // Each slice steps out along its own bisector, which leaves an even gap with no surface colour to match.
                var origin = new Point(center.X + Math.Cos(middle), center.Y + Math.Sin(middle));
                Point Rim(double at) => new(origin.X + radius * Math.Cos(at), origin.Y + radius * Math.Sin(at));
                var slice = new StreamGeometry();
                using (var sink = slice.Open())
                {
                    sink.BeginFigure(origin, true, true);
                    sink.LineTo(Rim(angle), true, false);
                    sink.ArcTo(Rim(angle + sweep), new(radius, radius), 0, sweep > Math.PI, SweepDirection.Clockwise, true, false);
                }
                slice.Freeze(); context.DrawGeometry(fill, null, slice);
            }
            angle += sweep;
        }
        var left = center.X + radius + 20; var room = ActualWidth - left;
        if (room < 60) return;
        var rows = Math.Min(slices.Count, LegendRows); var y = Math.Max(0, (ActualHeight - rows * LabelRow) / 2);
        for (var i = 0; i < rows; i++)
        {
            var more = i == LegendRows - 1 && slices.Count > LegendRows;
            if (!more) context.DrawEllipse(Series(i), null, new(left + 4, y + LabelRow / 2), 4, 4);
            var share = slices[i].Magnitude / total;
            context.DrawText(Text(more ? "+ " + (slices.Count - i) + " more" : slices[i].Label + "  " + (share * 100).ToString("0", CultureInfo.InvariantCulture) + "%", Muted, room - 16), new(left + 14, y + (LabelRow - 14) / 2));
            y += LabelRow;
        }
    }
}
