using System.Windows;
using System.Windows.Media;

namespace QNotch.Modules.Ai;

/// <summary>Thin progress bar that turns warning / danger colored as usage climbs. Renders only when Percent or a brush changes.</summary>
public sealed class UsageBar : FrameworkElement
{
    static DependencyProperty BrushDp(string name) => DependencyProperty.Register(name, typeof(Brush), typeof(UsageBar), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty PercentProperty = DependencyProperty.Register(nameof(Percent), typeof(double), typeof(UsageBar),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));
    static readonly DependencyProperty TrackProperty = BrushDp("Track"), NormalProperty = BrushDp("Normal"), WarnProperty = BrushDp("Warn"), DangerProperty = BrushDp("Danger");

    public UsageBar()
    {
        Height = 5;
        SetResourceReference(TrackProperty, "ControlHoverBrush");
        SetResourceReference(NormalProperty, "AccentBrush");
        SetResourceReference(WarnProperty, "WarningBrush");
        SetResourceReference(DangerProperty, "DangerBrush");
    }

    public double Percent { get => (double)GetValue(PercentProperty); set => SetValue(PercentProperty, value); }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight, r = h / 2;
        if (w <= 0 || h <= 0) return;
        dc.DrawRoundedRectangle((Brush?)GetValue(TrackProperty), null, new Rect(0, 0, w, h), r, r);
        var pct = Math.Clamp(Percent, 0, 100);
        if (pct <= 0) return;
        var fill = (Brush?)GetValue(pct >= 90 ? DangerProperty : pct >= 75 ? WarnProperty : NormalProperty);
        dc.DrawRoundedRectangle(fill, null, new Rect(0, 0, Math.Max(h, w * pct / 100), h), r, r);
    }
}
