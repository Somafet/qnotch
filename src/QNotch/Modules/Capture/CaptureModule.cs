using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using CommunityToolkit.Mvvm.ComponentModel;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Capture;

internal sealed partial class CaptureState : ObservableObject
{
    [ObservableProperty] bool _micInUse;
    [ObservableProperty] bool _cameraInUse;
    [ObservableProperty] bool _anyInUse;
    /// <summary>"Microphone: Teams. Camera: Teams." for screen readers and the tooltip.</summary>
    [ObservableProperty] string _description = "";
}

/// <summary>
/// A microphone and a camera glyph in the pill and the game bar while any app uses them. Two <see cref="CaptureWatch"/>es report
/// changes from the registry; there is no timer.
/// </summary>
public sealed class CaptureModule : INotchModule
{
    const string Mic = "", Cam = "";

    readonly CaptureState _st = new();
    IReadOnlyList<string> _mic = [], _cam = [];
    CaptureWatch? _micWatch, _camWatch; // kept alive for the app's lifetime

    public void Initialize(ModuleContext ctx)
    {
        ctx.Segments.Register(new SegmentDescriptor("capture.pill", SegmentSlot.PillRight, 3, Segment));
        ctx.Segments.Register(new SegmentDescriptor("capture.game", SegmentSlot.GameBar, 12, Segment,
            "Mic and camera", "Only while an app uses the microphone or camera."));

        if (ctx.Settings.ReadOnly) { Apply(["Teams"], ["Teams"]); return; } // snapshot run: demo data, no watchers
        _micWatch = new CaptureWatch(CaptureWatch.Microphone, apps => ctx.Bus.Run(() => Apply(apps, _cam)));
        _camWatch = new CaptureWatch(CaptureWatch.Camera, apps => ctx.Bus.Run(() => Apply(_mic, apps)));
    }

    void Apply(IReadOnlyList<string> mic, IReadOnlyList<string> cam)
    {
        (_mic, _cam) = (mic, cam);
        _st.MicInUse = mic.Count > 0;
        _st.CameraInUse = cam.Count > 0;
        _st.AnyInUse = _st.MicInUse || _st.CameraInUse;
        var parts = new List<string>();
        if (mic.Count > 0) parts.Add($"Microphone: {string.Join(", ", mic)}.");
        if (cam.Count > 0) parts.Add($"Camera: {string.Join(", ", cam)}.");
        _st.Description = string.Join(" ", parts);
    }

    /// <summary>Same element in the pill and the game bar.</summary>
    FrameworkElement Segment()
    {
        var mic = UiKit.BindVisible(UiKit.Glyph(Mic, 12, "WarningBrush"), _st, nameof(CaptureState.MicInUse));
        var cam = UiKit.BindVisible(UiKit.Glyph(Cam, 12, "SuccessBrush"), _st, nameof(CaptureState.CameraInUse));
        mic.VerticalAlignment = cam.VerticalAlignment = VerticalAlignment.Center;
        cam.Margin = new Thickness(4, 0, 0, 0);
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(mic);
        p.Children.Add(cam);
        UiKit.Bind(p, AutomationProperties.NameProperty, _st, nameof(CaptureState.Description));
        UiKit.Bind(p, FrameworkElement.ToolTipProperty, _st, nameof(CaptureState.Description));
        return UiKit.BindVisible(p, _st, nameof(CaptureState.AnyInUse));
    }
}
