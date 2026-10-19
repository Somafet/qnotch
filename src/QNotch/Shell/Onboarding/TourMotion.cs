using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// The tour's motion vocabulary (spec/onboarding.md, Motion): quick ease-out entrances, ease-in exits, a gentle overshoot only for success.
/// Only opacity and render transforms are animated. Every tween ends with FillBehavior.Stop on top of the final local value, so nothing keeps
/// a clock alive once it finished; a delayed tween holds its start value from time zero (no flash of the final state before it starts).
/// </summary>
internal static class TourMotion
{
    public static readonly IEasingFunction Out = Frozen(new CubicEase { EasingMode = EasingMode.EaseOut });
    public static readonly IEasingFunction OutQuint = Frozen(new QuinticEase { EasingMode = EasingMode.EaseOut });
    public static readonly IEasingFunction In = Frozen(new CubicEase { EasingMode = EasingMode.EaseIn });
    public static readonly IEasingFunction Spring = Frozen(new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.45 });

    static IEasingFunction Frozen(EasingFunctionBase e) { e.Freeze(); return e; }

    static KeyTime At(double ms) => KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(ms));

    /// <summary>from to <paramref name="to"/> over <paramref name="ms"/>, after <paramref name="delay"/> spent holding <paramref name="from"/>.</summary>
    public static DoubleAnimationUsingKeyFrames Tween(double from, double to, double ms, double delay = 0, IEasingFunction? ease = null)
    {
        var a = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
        a.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, At(0)));
        if (delay > 0) a.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, At(delay)));
        a.KeyFrames.Add(new EasingDoubleKeyFrame(to, At(delay + ms), ease ?? Out));
        return a;
    }

    /// <summary>Animates <paramref name="p"/> of <paramref name="target"/> and leaves it at <paramref name="to"/>.</summary>
    public static void Run(IAnimatable target, DependencyProperty p, double from, double to, double ms, double delay = 0, IEasingFunction? ease = null, Action? done = null)
    {
        ((DependencyObject)target).SetValue(p, to);
        var a = Tween(from, to, ms, delay, ease);
        if (done is not null) a.Completed += (_, _) => done();
        target.BeginAnimation(p, a);
    }

    /// <summary>The element's scale and translate (created once, as a TransformGroup), scaling about <paramref name="origin"/>.</summary>
    public static (ScaleTransform Scale, TranslateTransform Move) Xf(UIElement el, Point? origin = null)
    {
        if (el.RenderTransform is TransformGroup { Children: [ScaleTransform s, TranslateTransform t] })
        {
            if (origin is { } o) el.RenderTransformOrigin = o;
            return (s, t);
        }
        var scale = new ScaleTransform();
        var move = new TranslateTransform();
        el.RenderTransform = new TransformGroup { Children = { scale, move } };
        el.RenderTransformOrigin = origin ?? new Point(0.5, 0.5);
        return (scale, move);
    }

    /// <summary>Fades in while gliding from (<paramref name="dx"/>, <paramref name="dy"/>) to its place.</summary>
    public static void Enter(UIElement el, double dx, double dy, double ms, double delay = 0, IEasingFunction? ease = null)
    {
        Run(el, UIElement.OpacityProperty, 0, 1, ms, delay, Out);
        var (_, move) = Xf(el);
        if (dx != 0) Run(move, TranslateTransform.XProperty, dx, 0, ms, delay, ease ?? Out);
        if (dy != 0) Run(move, TranslateTransform.YProperty, dy, 0, ms, delay, ease ?? Out);
    }

    /// <summary>A success pop: from <paramref name="from"/> past 1 (about 1.08) and back, fading in on the way.</summary>
    public static void Pop(UIElement el, double from = 0.6, double ms = 420, double delay = 0)
    {
        var (scale, _) = Xf(el, new Point(0.5, 0.5));
        foreach (var p in new[] { ScaleTransform.ScaleXProperty, ScaleTransform.ScaleYProperty })
        {
            scale.SetValue(p, 1.0);
            var a = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
            a.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, At(0)));
            if (delay > 0) a.KeyFrames.Add(new DiscreteDoubleKeyFrame(from, At(delay)));
            a.KeyFrames.Add(new EasingDoubleKeyFrame(1.08, At(delay + ms * 0.55), Out));
            a.KeyFrames.Add(new EasingDoubleKeyFrame(1, At(delay + ms), new SineEase { EasingMode = EasingMode.EaseInOut }));
            scale.BeginAnimation(p, a);
        }
        Run(el, UIElement.OpacityProperty, 0, 1, ms * 0.4, delay);
    }

    /// <summary>A key press: down to <paramref name="depth"/> and back up.</summary>
    public static void Press(UIElement el, double delay, double down = 90, double up = 170, double depth = 0.92)
    {
        var (scale, move) = Xf(el, new Point(0.5, 0.6));
        void Key(IAnimatable t, DependencyProperty p, double rest, double pressed)
        {
            var a = new DoubleAnimationUsingKeyFrames { FillBehavior = FillBehavior.Stop };
            a.KeyFrames.Add(new DiscreteDoubleKeyFrame(rest, At(0)));
            if (delay > 0) a.KeyFrames.Add(new DiscreteDoubleKeyFrame(rest, At(delay)));
            a.KeyFrames.Add(new EasingDoubleKeyFrame(pressed, At(delay + down), Out));
            a.KeyFrames.Add(new EasingDoubleKeyFrame(rest, At(delay + down + up), Out));
            t.BeginAnimation(p, a);
        }
        Key(scale, ScaleTransform.ScaleXProperty, 1, depth);
        Key(scale, ScaleTransform.ScaleYProperty, 1, depth);
        Key(move, TranslateTransform.YProperty, 0, 2);
    }

    /// <summary>Drops every animation on an element and its transforms (a view that leaves early).</summary>
    public static void Clear(UIElement el)
    {
        el.BeginAnimation(UIElement.OpacityProperty, null);
        if (el.RenderTransform is TransformGroup { Children: [ScaleTransform s, TranslateTransform t] })
        {
            s.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            s.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            t.BeginAnimation(TranslateTransform.XProperty, null);
            t.BeginAnimation(TranslateTransform.YProperty, null);
        }
    }
}
