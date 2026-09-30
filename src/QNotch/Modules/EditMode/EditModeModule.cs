using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Shell;

namespace QNotch.Modules.EditMode;

/// <summary>
/// Home edit mode: cards jiggle, lift on drag, other cards slide to their new slots, the dragged card settles on drop.
/// Everything lives on CardHost.RenderTransform (scale, rotate, translate) and is removed as soon as edit mode ends
/// (the shell turns it off when the panel closes), so the module costs nothing while collapsed.
/// The order is persisted live through CardLayout.Move, which keeps hidden cards in the order list.
/// </summary>
public sealed class EditModeModule : INotchModule
{
    const double Lift = 1.05, Threshold = 4, EdgeZone = 32, MaxScroll = 14;
    const int ReorderCooldownMs = 140;

    /// <summary>Per-card transform stack: scale (lift), rotate (jiggle), translate (drag and slide). Gen invalidates stale settle callbacks.</summary>
    sealed class Fx
    {
        public readonly ScaleTransform Scale = new(1, 1);
        public readonly RotateTransform Rot = new();
        public readonly TranslateTransform Move = new();
        public int Gen;
    }

    ModuleContext _ctx = null!;
    readonly Dictionary<CardHost, Fx> _fx = new();
    ScrollViewer? _sv;
    Panel? _panel;
    bool _editing;

    CardHost? _press;
    Point _pressPos;
    Vector _grab;
    bool _dragging;
    long _lastReorder;
    IDisposable? _hold;
    DispatcherTimer? _scrollTimer;
    double _scrollSpeed;

    public string Id => "editmode";

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Shell.EditModeChanged += Sync;
        ctx.CardLayout.HostsChanged += () => { if (ctx.Shell.IsEditMode) Sync(); };
    }

    void Sync()
    {
        if (!_ctx.Shell.IsEditMode) { Stop(); return; }
        if (!_editing) Start();
        if (_editing) Ensure();
    }

    void Start()
    {
        var hosts = _ctx.CardLayout.Hosts;
        if (hosts.Count == 0 || VisualTreeHelper.GetParent(hosts[0]) is not Panel panel) return;
        var sv = Ancestor<ScrollViewer>(panel);
        if (sv == null) return;
        _panel = panel;
        _sv = sv;
        _editing = true;
        sv.PreviewMouseLeftButtonDown += OnDown;
        sv.PreviewMouseMove += OnMove;
        sv.PreviewMouseLeftButtonUp += OnUp;
        sv.LostMouseCapture += OnLostCapture;
    }

    void Stop()
    {
        if (!_editing) return;
        _editing = false;
        var sv = _sv!;
        sv.PreviewMouseLeftButtonDown -= OnDown;
        sv.PreviewMouseMove -= OnMove;
        sv.PreviewMouseLeftButtonUp -= OnUp;
        sv.LostMouseCapture -= OnLostCapture;
        if (sv.IsMouseCaptured) sv.ReleaseMouseCapture();
        EndDrag(false);
        foreach (var (h, f) in _fx) Reset(h, f);
        _fx.Clear();
        _sv = null;
        _panel = null;
    }

    /// <summary>Gives every live host its transform stack and jiggle (idempotent: hosts are reused across rebuilds).</summary>
    void Ensure()
    {
        foreach (var h in _ctx.CardLayout.Hosts)
        {
            if (_fx.ContainsKey(h)) continue;
            var f = new Fx();
            var g = new TransformGroup();
            g.Children.Add(f.Scale);
            g.Children.Add(f.Rot);
            g.Children.Add(f.Move);
            h.RenderTransformOrigin = new Point(0.5, 0.5);
            h.RenderTransform = g;
            _fx[h] = f;
            Jiggle(h, f);
        }
    }

    static void Reset(CardHost h, Fx f)
    {
        f.Gen++;
        Snap(f.Rot, RotateTransform.AngleProperty);
        Snap(f.Scale, ScaleTransform.ScaleXProperty);
        Snap(f.Scale, ScaleTransform.ScaleYProperty);
        Snap(f.Move, TranslateTransform.XProperty);
        Snap(f.Move, TranslateTransform.YProperty);
        h.ClearValue(UIElement.RenderTransformProperty);
        h.ClearValue(UIElement.RenderTransformOriginProperty);
        h.ClearValue(UIElement.EffectProperty);
        h.ClearValue(Panel.ZIndexProperty);
    }

    // ---- Jiggle ----

    static void Jiggle(CardHost h, Fx f)
    {
        if (!Motion.Enabled) return;
        var seed = 0;
        foreach (var c in h.CardId) seed += c;
        var a = new DoubleAnimation(-(0.7 + seed % 3 * 0.1), 0.7 + seed % 3 * 0.1, TimeSpan.FromMilliseconds(120 + seed % 5 * 12))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut },
            BeginTime = TimeSpan.FromMilliseconds(-(seed % 7) * 17), // desync neighbours
        };
        Timeline.SetDesiredFrameRate(a, 30); // each frame repaints the whole notch surface
        f.Rot.BeginAnimation(RotateTransform.AngleProperty, a);
    }

    // ---- Mouse handling (on the Home ScrollViewer, so capture survives card rebuilds) ----

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        var h = Ancestor<CardHost>(e.OriginalSource as DependencyObject);
        if (h == null || !_fx.ContainsKey(h) || _press != null) return;
        e.Handled = true; // edit mode: card contents are not clickable
        _press = h;
        _pressPos = e.GetPosition(_panel);
        _sv!.CaptureMouse();
    }

    void OnMove(object sender, MouseEventArgs e)
    {
        if (_press == null) return;
        if (!_dragging)
        {
            if ((e.GetPosition(_panel) - _pressPos).Length < Threshold) return;
            BeginDrag();
        }
        Update();
        AutoScroll(e.GetPosition(_sv));
    }

    void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (_press == null) return;
        e.Handled = true;
        _sv!.ReleaseMouseCapture(); // raises LostMouseCapture, which settles the card
    }

    void OnLostCapture(object sender, MouseEventArgs e) => EndDrag(true);

    // ---- Drag ----

    void BeginDrag()
    {
        var h = _press!;
        var f = _fx[h];
        _dragging = true;
        _hold = _ctx.Shell.HoldOpen();
        f.Gen++;
        Snap(f.Move, TranslateTransform.XProperty);
        Snap(f.Move, TranslateTransform.YProperty);
        var slot = VisualTreeHelper.GetOffset(h);
        _grab = _pressPos - new Point(slot.X + f.Move.X, slot.Y + f.Move.Y);

        // Lift: straighten, scale up, shadow on this card only (effect is removed again after the settle).
        Panel.SetZIndex(h, 10);
        h.Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 6, Direction = 270, Opacity = 0.45, Color = Colors.Black, RenderingBias = RenderingBias.Performance };
        Tween(f.Rot, RotateTransform.AngleProperty, f.Rot.Angle, 0, 120);
        Tween(f.Scale, ScaleTransform.ScaleXProperty, f.Scale.ScaleX, Lift, 140);
        Tween(f.Scale, ScaleTransform.ScaleYProperty, f.Scale.ScaleY, Lift, 140);
    }

    /// <summary>Keeps the dragged card under the pointer and reorders when its center enters another card's slot.</summary>
    void Update()
    {
        var h = _press!;
        Place(h);
        if (Environment.TickCount64 - _lastReorder < ReorderCooldownMs) return;
        var center = Mouse.GetPosition(_panel) - _grab + new Vector(h.ActualWidth / 2, h.ActualHeight / 2);
        foreach (var o in _ctx.CardLayout.Hosts)
            if (o != h && new Rect((Point)VisualTreeHelper.GetOffset(o), new Size(o.ActualWidth, o.ActualHeight)).Contains(center))
            {
                Reorder(h, o);
                Place(h);
                return;
            }
    }

    void Place(CardHost h)
    {
        var f = _fx[h];
        var p = Mouse.GetPosition(_panel);
        var slot = VisualTreeHelper.GetOffset(h);
        f.Move.X = p.X - _grab.X - slot.X;
        f.Move.Y = p.Y - _grab.Y - slot.Y;
    }

    void Reorder(CardHost dragged, CardHost target)
    {
        var before = _ctx.CardLayout.Hosts.ToDictionary(x => x, VisualTreeHelper.GetOffset);
        _ctx.CardLayout.Move(dragged.CardId, target.CardId); // HomeView rebuilds synchronously
        _panel!.UpdateLayout();
        _lastReorder = Environment.TickCount64;
        foreach (var o in _ctx.CardLayout.Hosts)
        {
            if (o == dragged || !_fx.TryGetValue(o, out var f) || !before.TryGetValue(o, out var b)) continue;
            var d = b - VisualTreeHelper.GetOffset(o);
            if (d.X == 0 && d.Y == 0) continue;
            Tween(f.Move, TranslateTransform.XProperty, f.Move.X + d.X, 0, 220);
            Tween(f.Move, TranslateTransform.YProperty, f.Move.Y + d.Y, 0, 220);
        }
    }

    void EndDrag(bool settle)
    {
        _scrollTimer?.Stop();
        _scrollSpeed = 0;
        _hold?.Dispose();
        _hold = null;
        var h = _press;
        var was = _dragging;
        _press = null;
        _dragging = false;
        if (!settle || !was || h == null || !_fx.TryGetValue(h, out var f)) return;

        var gen = ++f.Gen;
        var ease = new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.35 };
        Tween(f.Scale, ScaleTransform.ScaleXProperty, f.Scale.ScaleX, 1, 240, ease);
        Tween(f.Scale, ScaleTransform.ScaleYProperty, f.Scale.ScaleY, 1, 240, ease);
        Tween(f.Move, TranslateTransform.YProperty, f.Move.Y, 0, 240, ease);
        Tween(f.Move, TranslateTransform.XProperty, f.Move.X, 0, 240, ease, () =>
        {
            if (f.Gen != gen) return;
            h.ClearValue(UIElement.EffectProperty);
            h.ClearValue(Panel.ZIndexProperty);
            if (_editing) Jiggle(h, f);
        });
    }

    // ---- Auto scroll while dragging near the top or bottom edge (timer runs only then) ----

    void AutoScroll(Point p)
    {
        var h = _sv!.ActualHeight;
        _scrollSpeed = p.Y < EdgeZone ? -(1 - Math.Max(p.Y, 0) / EdgeZone) * MaxScroll
                     : p.Y > h - EdgeZone ? (1 - Math.Max(h - p.Y, 0) / EdgeZone) * MaxScroll : 0;
        if (_scrollSpeed == 0) { _scrollTimer?.Stop(); return; }
        _scrollTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Normal, (_, _) => ScrollTick(), _ctx.Dispatcher);
        _scrollTimer.Start();
    }

    void ScrollTick()
    {
        if (!_dragging || _sv == null) { _scrollTimer?.Stop(); return; }
        _sv.ScrollToVerticalOffset(_sv.VerticalOffset + _scrollSpeed);
        _sv.UpdateLayout();
        Update();
    }

    // ---- Helpers ----

    /// <summary>Animates a transform property to <paramref name="to"/>; the final value is set locally so the animation can simply stop. Without motion it jumps.</summary>
    static void Tween(Animatable t, DependencyProperty p, double from, double to, int ms, IEasingFunction? ease = null, Action? done = null)
    {
        t.SetValue(p, to);
        if (!Motion.Enabled || from == to)
        {
            ((IAnimatable)t).BeginAnimation(p, null);
            done?.Invoke();
            return;
        }
        var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms))
        {
            EasingFunction = ease ?? new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop,
        };
        if (done != null) a.Completed += (_, _) => done();
        ((IAnimatable)t).BeginAnimation(p, a);
    }

    /// <summary>Freezes a property at its current animated value and removes the animation.</summary>
    static void Snap(Animatable t, DependencyProperty p)
    {
        var v = t.GetValue(p);
        ((IAnimatable)t).BeginAnimation(p, null);
        t.SetValue(p, v);
    }

    static T? Ancestor<T>(DependencyObject? d) where T : DependencyObject
    {
        while (d != null)
        {
            if (d is T t) return t;
            d = d is Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(d) : LogicalTreeHelper.GetParent(d);
        }
        return null;
    }
}
