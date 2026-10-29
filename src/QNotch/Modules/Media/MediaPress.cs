using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using QNotch.Core;

namespace QNotch.Modules.Media;

/// <summary>Pointer-only press feedback. Keyboard activation stays instant.</summary>
public static class MediaPress
{
    public static readonly DependencyProperty EnabledProperty = DependencyProperty.RegisterAttached(
        "Enabled", typeof(bool), typeof(MediaPress), new PropertyMetadata(false, Changed));

    public static bool GetEnabled(DependencyObject target) => (bool)target.GetValue(EnabledProperty);
    public static void SetEnabled(DependencyObject target, bool value) => target.SetValue(EnabledProperty, value);

    static void Changed(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
        if (target is not Button button) return;
        if ((bool)e.NewValue)
        {
            button.RenderTransformOrigin = new Point(0.5, 0.5);
            button.RenderTransform = new ScaleTransform(1, 1);
            button.PreviewMouseLeftButtonDown += Press;
            button.PreviewMouseLeftButtonUp += Release;
            button.LostMouseCapture += Release;
            button.MouseLeave += Release;
            button.Unloaded += Unload;
        }
        else
        {
            button.PreviewMouseLeftButtonDown -= Press;
            button.PreviewMouseLeftButtonUp -= Release;
            button.LostMouseCapture -= Release;
            button.MouseLeave -= Release;
            button.Unloaded -= Unload;
            Scale(button, 1, false);
        }
    }

    static void Press(object sender, MouseButtonEventArgs e)
    {
        if (sender is Button { IsEnabled: true } button && Motion.Enabled) Scale(button, 0.97, true);
    }

    static void Release(object sender, MouseEventArgs e) => Scale((Button)sender, 1, Motion.Enabled);
    static void Unload(object sender, RoutedEventArgs e) => Scale((Button)sender, 1, false);

    static void Scale(Button button, double value, bool animate)
    {
        if (button.RenderTransform is not ScaleTransform scale) return;
        foreach (var property in new[] { ScaleTransform.ScaleXProperty, ScaleTransform.ScaleYProperty })
        {
            if (animate)
            {
                var animation = new DoubleAnimation(value, TimeSpan.FromMilliseconds(120))
                {
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                    FillBehavior = FillBehavior.Stop
                };
                // Begin from the current animated value so rapid presses can retarget smoothly.
                animation.From = (double)scale.GetValue(property);
                scale.SetValue(property, value);
                scale.BeginAnimation(property, animation);
            }
            else
            {
                scale.BeginAnimation(property, null);
                scale.SetValue(property, value);
            }
        }
    }
}
