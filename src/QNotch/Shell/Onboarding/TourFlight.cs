using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using QNotch.Core;
using QNotch.Interop;

namespace QNotch.Shell.Onboarding;

/// <summary>
/// Open QNotch: the tour shrinks and flies into the notch at the top center of its monitor, and the real panel opens as it arrives.
/// A picture of the tour rides in a short-lived transparent window (the tour itself is cloaked, so its frame and shadow vanish at once);
/// the ghost covers only the strip between the tour and the notch and closes when it lands.
/// </summary>
internal static class TourFlight
{
    const double Ms = 360, ArriveAt = 0.75, EndScale = 0.3;
    /// <summary>A gentle ease-in: the move starts at once and spreads over the frames (a cubic one would save it all for the last two).</summary>
    static readonly IEasingFunction Fall = Frozen(new QuadraticEase { EasingMode = EasingMode.EaseIn });
    static IEasingFunction Frozen(EasingFunctionBase e) { e.Freeze(); return e; }

    /// <param name="arrive">Called near the end, when the picture reaches the notch (opens the panel).</param>
    /// <param name="done">Called once the ghost is gone (closes the tour). Also the fallback when anything fails.</param>
    public static void Fly(Window tour, FrameworkElement root, int monitorIndex, Action arrive, Action done)
    {
        Window? ghost = null;
        var arrived = false;
        void Arrive() { if (arrived) return; arrived = true; arrive(); }
        void Finish()
        {
            Arrive();
            try { ghost?.Close(); } catch { }
            done();
        }
        try
        {
            var dpi = VisualTreeHelper.GetDpi(root);
            var s = dpi.DpiScaleX;
            var w = root.ActualWidth;
            var h = root.ActualHeight;
            var origin = root.PointToScreen(new Point(0, 0)); // physical pixels
            var mon = Monitors.Get(monitorIndex).Bounds;
            // The notch sits at the top center of its monitor; a tour on another monitor flies to the top of its own.
            var tourMon = Monitors.List().FirstOrDefault(m => origin.X >= m.Bounds.Left && origin.X < m.Bounds.Right && origin.Y >= m.Bounds.Top && origin.Y < m.Bounds.Bottom)?.Bounds;
            if (tourMon is { } tm && (mon.Left != tm.Left || mon.Top != tm.Top)) mon = tm;
            double tx = mon.Left + mon.Width / 2.0, ty = mon.Top;

            var pic = new RenderTargetBitmap((int)Math.Ceiling(w * s), (int)Math.Ceiling(h * s), dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            pic.Render(root);
            pic.Freeze();
            // The tour answers at once with a slight lift (setting up the ghost takes a few frames); the ghost then flies on from there.
            var (lift, _) = TourMotion.Xf(root, new Point(0.5, 0));
            TourMotion.Run(lift, ScaleTransform.ScaleXProperty, 1, 0.97, 160, 0, TourMotion.Out);
            TourMotion.Run(lift, ScaleTransform.ScaleYProperty, 1, 0.97, 160, 0, TourMotion.Out);

            // Ghost bounds in pixels: the tour, stretched up to the top of the monitor and sideways to the notch.
            var left = Math.Min(origin.X, tx - 20);
            var right = Math.Max(origin.X + w * s, tx + 20);
            var top = Math.Min(origin.Y, ty);
            var bottom = origin.Y + h * s;
            var image = new Image
            {
                Source = pic, Width = w, Height = h, Stretch = Stretch.Fill,
                Clip = new RectangleGeometry(new Rect(0, 0, w, h), 8, 8), // the window's rounded corners
            };
            Canvas.SetLeft(image, (origin.X - left) / s);
            Canvas.SetTop(image, (origin.Y - top) / s);
            var (scale, move) = TourMotion.Xf(image, new Point(0.5, 0));
            ghost = new Window
            {
                WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent, ShowInTaskbar = false, ShowActivated = false,
                Topmost = true, ResizeMode = ResizeMode.NoResize, IsHitTestVisible = false, Focusable = false,
                Width = (right - left) / s, Height = (bottom - top) / s, Content = new Canvas { Children = { image } },
                WindowStartupLocation = WindowStartupLocation.Manual, Left = -32000, Top = -32000,
            };
            ghost.SourceInitialized += (_, _) =>
            {
                var hwnd = new WindowInteropHelper(ghost).Handle;
                Native.SetWindowPos(hwnd, 0, (int)left, (int)top, (int)Math.Ceiling(right - left), (int)Math.Ceiling(bottom - top), Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
            };
            ghost.ContentRendered += (_, _) =>
            {
                var s0 = lift.ScaleX;
                Cloak(tour);
                // Top center of the picture to the notch.
                var dx = (tx - left) / s - ((origin.X - left) / s + w / 2);
                var dy = (ty - top) / s - (origin.Y - top) / s;
                TourMotion.Run(scale, ScaleTransform.ScaleXProperty, s0, EndScale, Ms, 0, Fall);
                TourMotion.Run(scale, ScaleTransform.ScaleYProperty, s0, EndScale, Ms, 0, Fall);
                TourMotion.Run(move, TranslateTransform.XProperty, 0, dx, Ms, 0, Fall);
                TourMotion.Run(move, TranslateTransform.YProperty, 0, dy, Ms, 0, Fall, Finish);
                // Fully visible for most of the way, so it is seen going into the notch; gone as it lands.
                TourMotion.Run(image, UIElement.OpacityProperty, 1, 0, Ms * 0.35, Ms * 0.65, TourMotion.In);
                var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(Ms * ArriveAt) };
                timer.Tick += (_, _) => { timer.Stop(); Arrive(); };
                timer.Start();
            };
            ghost.Show();
        }
        catch (Exception ex)
        {
            Log.Warn("The welcome tour handoff animation failed", ex);
            Finish();
        }
    }

    /// <summary>Hides a window at once through DWM (no close animation, no change to its visibility or a modal loop).</summary>
    static void Cloak(Window w)
    {
        var hwnd = new WindowInteropHelper(w).Handle;
        if (hwnd == 0) return;
        int on = 1;
        Native.DwmSetWindowAttribute(hwnd, 13, ref on, 4); // DWMWA_CLOAK
    }
}
