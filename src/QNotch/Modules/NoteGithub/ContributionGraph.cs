using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace QNotch.Modules.NoteGithub;

/// <summary>
/// The 53 x 7 contribution grid, drawn in one OnRender pass (retained by WPF until Data, size, theme or accent changes).
/// No per-cell elements. Levels 1 to 4 are the accent color at increasing opacity; level 0 uses the theme's hover fill.
/// </summary>
public sealed class ContributionGraph : FrameworkElement
{
    public static readonly double[] LevelOpacity = [0, 0.3, 0.52, 0.76, 1];

    public static readonly DependencyProperty DataProperty = DependencyProperty.Register(nameof(Data), typeof(GithubData), typeof(ContributionGraph),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender, (o, _) => ((ContributionGraph)o)._tipIndex = -1));
    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(nameof(Accent), typeof(Brush), typeof(ContributionGraph),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty EmptyProperty = DependencyProperty.Register(nameof(Empty), typeof(Brush), typeof(ContributionGraph),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    readonly ToolTip _tip = new();
    int _tipIndex = -1;

    public ContributionGraph()
    {
        SetResourceReference(AccentProperty, "AccentBrush");
        SetResourceReference(EmptyProperty, "ControlHoverBrush");
        SnapsToDevicePixels = true;
        ToolTip = _tip;
        ToolTipService.SetInitialShowDelay(this, 120);
        ToolTipService.SetPlacement(this, System.Windows.Controls.Primitives.PlacementMode.Top);
    }

    public GithubData? Data { get => (GithubData?)GetValue(DataProperty); set => SetValue(DataProperty, value); }
    public Brush? Accent { get => (Brush?)GetValue(AccentProperty); set => SetValue(AccentProperty, value); }
    public Brush? Empty { get => (Brush?)GetValue(EmptyProperty); set => SetValue(EmptyProperty, value); }

    protected override Size MeasureOverride(Size s) =>
        new(double.IsInfinity(s.Width) ? 371 : s.Width, double.IsInfinity(s.Height) ? 49 : s.Height);

    /// <summary>Grid geometry for the current size: first Sunday, column count, cell pitch and origin.</summary>
    (DateOnly First, int Cols, double Pitch, double X0, double Y0) Layout(GithubData d)
    {
        var first = d.Days[0].Date;
        first = first.AddDays(-(int)first.DayOfWeek);
        var cols = (d.Days[^1].Date.DayNumber - first.DayNumber) / 7 + 1;
        var pitch = Math.Max(2, Math.Min(ActualWidth / cols, ActualHeight / 7));
        return (first, cols, pitch, (ActualWidth - cols * pitch) / 2, (ActualHeight - 7 * pitch) / 2);
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (Data is not { Days.Count: > 0 } d || Accent is null || Empty is null) return;
        var (first, _, pitch, x0, y0) = Layout(d);
        var cell = pitch * 0.8;
        var r = Math.Max(1, cell * 0.24);
        var inset = (pitch - cell) / 2;
        for (var level = 0; level < 5; level++)
        {
            var opacity = LevelOpacity[level];
            if (level > 0) dc.PushOpacity(opacity);
            var brush = level == 0 ? Empty : Accent;
            foreach (var day in d.Days)
            {
                if (day.Level != level) continue;
                var n = day.Date.DayNumber - first.DayNumber;
                dc.DrawRoundedRectangle(brush, null, new Rect(x0 + n / 7 * pitch + inset, y0 + n % 7 * pitch + inset, cell, cell), r, r);
            }
            if (level > 0) dc.Pop();
        }
    }

    protected override HitTestResult? HitTestCore(PointHitTestParameters p) => new PointHitTestResult(this, p.HitPoint);

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (Data is not { Days.Count: > 0 } d) return;
        var (first, _, pitch, x0, y0) = Layout(d);
        var p = e.GetPosition(this);
        var col = (int)Math.Floor((p.X - x0) / pitch);
        var row = (int)Math.Floor((p.Y - y0) / pitch);
        var n = col * 7 + row;
        var idx = col < 0 || row < 0 || row > 6 ? -1 : n - (d.Days[0].Date.DayNumber - first.DayNumber);
        if (idx < 0 || idx >= d.Days.Count || idx == _tipIndex) return;
        _tipIndex = idx;
        var day = d.Days[idx];
        _tip.Content = $"{(day.Count == 0 ? "No contributions" : day.Count == 1 ? "1 contribution" : $"{day.Count} contributions")} on {day.Date.ToString("ddd, MMM d", QNotch.Core.UiCulture.Value)}";
    }

    protected override void OnMouseLeave(MouseEventArgs e) { base.OnMouseLeave(e); _tipIndex = -1; }
}
