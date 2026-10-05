using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using QNotch.Core;
using static QNotch.Shell.EditModeController;

namespace QNotch.Shell;

/// <summary>
/// Edit mode for the tab strip: tabs jiggle like the cards and are dragged sideways to reorder (ShellController.MoveTab saves it).
/// A press without a drag still opens the tab. Transforms are removed as soon as edit mode ends.
/// </summary>
internal sealed class TabReorderController
{
    const double Lift = 1.15, Threshold = 4, Angle = 2.5;
    const int ReorderCooldownMs = 140;

    sealed class Fx
    {
        public readonly ScaleTransform Scale = new(1, 1);
        public readonly RotateTransform Rot = new();
        public readonly TranslateTransform Move = new();
        public int Gen;
    }

    readonly ShellController _shell;
    readonly NotchWindow _w;
    readonly Dictionary<RadioButton, Fx> _fx = new();
    bool _editing;

    RadioButton? _press;
    double _pressX, _grab;
    bool _dragging;
    long _lastReorder;
    IDisposable? _hold;

    internal TabReorderController(ShellController shell, NotchWindow window)
    {
        _shell = shell;
        _w = window;
        shell.EditModeChanged += () => { if (shell.IsEditMode) Start(); else Stop(); };
    }

    Panel Strip => _w.TabStrip;

    void Start()
    {
        if (_editing) return;
        _editing = true;
        foreach (RadioButton rb in Strip.Children)
        {
            var f = new Fx();
            var g = new TransformGroup();
            g.Children.Add(f.Scale);
            g.Children.Add(f.Rot);
            g.Children.Add(f.Move);
            rb.RenderTransformOrigin = new Point(0.5, 0.5);
            rb.RenderTransform = g;
            _fx[rb] = f;
            Jiggle(f.Rot, Id(rb), Angle);
        }
        Strip.PreviewMouseLeftButtonDown += OnDown;
        Strip.PreviewMouseMove += OnMove;
        Strip.PreviewMouseLeftButtonUp += OnUp;
        Strip.LostMouseCapture += OnLostCapture;
    }

    void Stop()
    {
        if (!_editing) return;
        _editing = false;
        Strip.PreviewMouseLeftButtonDown -= OnDown;
        Strip.PreviewMouseMove -= OnMove;
        Strip.PreviewMouseLeftButtonUp -= OnUp;
        Strip.LostMouseCapture -= OnLostCapture;
        if (Strip.IsMouseCaptured) Strip.ReleaseMouseCapture();
        EndDrag(false);
        foreach (var (rb, f) in _fx)
        {
            f.Gen++;
            Snap(f.Rot, RotateTransform.AngleProperty);
            Snap(f.Scale, ScaleTransform.ScaleXProperty);
            Snap(f.Scale, ScaleTransform.ScaleYProperty);
            Snap(f.Move, TranslateTransform.XProperty);
            rb.ClearValue(UIElement.RenderTransformProperty);
            rb.ClearValue(UIElement.RenderTransformOriginProperty);
            rb.ClearValue(Panel.ZIndexProperty);
        }
        _fx.Clear();
        IndicatorToActive(false);
    }

    static string Id(RadioButton rb) => (string)rb.Tag;

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        var rb = Ancestor<RadioButton>(e.OriginalSource as DependencyObject);
        if (rb == null || !_fx.ContainsKey(rb) || _press != null) return;
        e.Handled = true; // a click opens the tab on release, unless it turned into a drag
        _press = rb;
        _pressX = e.GetPosition(Strip).X;
        Strip.CaptureMouse();
    }

    void OnMove(object sender, MouseEventArgs e)
    {
        if (_press == null) return;
        if (!_dragging)
        {
            if (Math.Abs(e.GetPosition(Strip).X - _pressX) < Threshold) return;
            BeginDrag();
        }
        Update();
    }

    void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (_press == null) return;
        e.Handled = true;
        var click = _dragging ? null : Id(_press);
        Strip.ReleaseMouseCapture(); // raises LostMouseCapture, which settles the tab
        if (click != null) _shell.SelectTab(click);
    }

    void OnLostCapture(object sender, MouseEventArgs e) => EndDrag(true);

    void BeginDrag()
    {
        var rb = _press!;
        var f = _fx[rb];
        _dragging = true;
        _hold = _shell.HoldOpen();
        f.Gen++;
        Snap(f.Move, TranslateTransform.XProperty);
        _grab = _pressX - (VisualTreeHelper.GetOffset(rb).X + f.Move.X);
        Panel.SetZIndex(rb, 10);
        Tween(f.Rot, RotateTransform.AngleProperty, f.Rot.Angle, 0, 120);
        Tween(f.Scale, ScaleTransform.ScaleXProperty, f.Scale.ScaleX, Lift, 140);
        Tween(f.Scale, ScaleTransform.ScaleYProperty, f.Scale.ScaleY, Lift, 140);
    }

    /// <summary>Keeps the dragged tab under the pointer (inside the strip) and reorders when its center enters another tab's slot.</summary>
    void Update()
    {
        var rb = _press!;
        var x = Place(rb);
        if (Environment.TickCount64 - _lastReorder < ReorderCooldownMs) return;
        var center = x + rb.ActualWidth / 2;
        foreach (RadioButton o in Strip.Children)
        {
            var ox = VisualTreeHelper.GetOffset(o).X;
            if (o == rb || center < ox || center > ox + o.ActualWidth) continue;
            Reorder(rb, o);
            Place(rb);
            return;
        }
    }

    /// <summary>Moves the tab to the pointer and returns its left edge in strip coordinates. The indicator follows the selected tab.</summary>
    double Place(RadioButton rb)
    {
        var x = Math.Clamp(Mouse.GetPosition(Strip).X - _grab, 0, Strip.ActualWidth - rb.ActualWidth);
        _fx[rb].Move.X = x - VisualTreeHelper.GetOffset(rb).X;
        if (rb.IsChecked == true) _w.MoveTabIndicator(x, false);
        return x;
    }

    void Reorder(RadioButton dragged, RadioButton target)
    {
        var before = _fx.Keys.ToDictionary(x => x, x => VisualTreeHelper.GetOffset(x).X);
        _shell.MoveTab(Id(dragged), Id(target));
        Strip.UpdateLayout();
        _lastReorder = Environment.TickCount64;
        foreach (var (o, f) in _fx)
        {
            if (o == dragged) continue;
            var d = before[o] - VisualTreeHelper.GetOffset(o).X;
            if (d != 0) Tween(f.Move, TranslateTransform.XProperty, f.Move.X + d, 0, 220);
        }
        if (dragged.IsChecked != true) IndicatorToActive(true);
    }

    void IndicatorToActive(bool animate)
    {
        foreach (RadioButton rb in Strip.Children)
            if (rb.IsChecked == true) _w.MoveTabIndicator(VisualTreeHelper.GetOffset(rb).X, animate);
    }

    void EndDrag(bool settle)
    {
        _hold?.Dispose();
        _hold = null;
        var rb = _press;
        var was = _dragging;
        _press = null;
        _dragging = false;
        if (!settle || !was || rb == null || !_fx.TryGetValue(rb, out var f)) return;

        var gen = ++f.Gen;
        var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.35 };
        Tween(f.Scale, ScaleTransform.ScaleXProperty, f.Scale.ScaleX, 1, 240, ease);
        Tween(f.Scale, ScaleTransform.ScaleYProperty, f.Scale.ScaleY, 1, 240, ease);
        Tween(f.Move, TranslateTransform.XProperty, f.Move.X, 0, 240, ease, () =>
        {
            if (f.Gen != gen) return;
            rb.ClearValue(Panel.ZIndexProperty);
            if (_editing) Jiggle(f.Rot, Id(rb), Angle);
        });
        IndicatorToActive(true);
    }
}
