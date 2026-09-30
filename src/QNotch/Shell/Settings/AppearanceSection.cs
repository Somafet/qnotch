using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

public static class AppearanceSection
{
    static readonly string[] Accents = ["#5B9DFF", "#7C83FF", "#B07CFF", "#FF7CB0", "#FF7A6B", "#FFB54D", "#4CD98C", "#3CC8D9"];

    public static FrameworkElement Create(GeneralSettings gs, CardLayout layout)
    {
        var page = UiKit.Page("Appearance");

        // Theme: segmented control
        var seg = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var mode in Enum.GetValues<ThemeChoice>())
        {
            var m = mode;
            var rb = new RadioButton { Style = (Style)Application.Current.FindResource("SegmentButton"), Content = m.ToString(), GroupName = "theme", IsChecked = gs.Theme == m };
            rb.Checked += (_, _) => gs.Theme = m;
            seg.Children.Add(rb);
        }
        var segBox = new Border { CornerRadius = new CornerRadius(8), Child = seg };
        segBox.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        page.Children.Add(UiKit.Row("Theme", "Follow Windows, or force dark or light.", segBox));

        // Accent swatches
        var sw = new StackPanel { Orientation = Orientation.Horizontal };
        var rings = new List<(Border ring, string hex)>();
        void Mark() { foreach (var (r, h) in rings) { if (string.Equals(h, gs.AccentColor, StringComparison.OrdinalIgnoreCase)) r.SetResourceReference(Border.BorderBrushProperty, "TextPrimaryBrush"); else r.BorderBrush = Brushes.Transparent; } }
        foreach (var hex in Accents)
        {
            var h = hex;
            var ring = new Border
            {
                Width = 26, Height = 26, CornerRadius = new CornerRadius(13), BorderThickness = new Thickness(2), Margin = new Thickness(0, 0, 6, 0), Cursor = Cursors.Hand,
                Background = Brushes.Transparent, ToolTip = h,
                Child = new Border { CornerRadius = new CornerRadius(10), Margin = new Thickness(2), Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(h)) },
            };
            ring.MouseEnter += (_, _) => { if (!string.Equals(h, gs.AccentColor, StringComparison.OrdinalIgnoreCase)) ring.SetResourceReference(Border.BorderBrushProperty, "StrokeStrongBrush"); };
            ring.MouseLeave += (_, _) => Mark();
            ring.MouseLeftButtonUp += (_, _) => { gs.AccentColor = h; Mark(); };
            rings.Add((ring, h));
            sw.Children.Add(ring);
        }
        Mark();
        page.Children.Add(UiKit.Row("Accent color", null, sw));

        page.Children.Add(UiKit.Row("Reduce motion", "Skips animations. Always on when Windows animation effects are off.", UiKit.Toggle(gs.ReduceMotion, v => gs.ReduceMotion = v)));

        // Profile
        var name = new TextBox { Width = 200, Text = gs.ProfileName };
        name.TextChanged += (_, _) => gs.ProfileName = name.Text;
        page.Children.Add(UiKit.Row("Display name", "Shown in the panel header.", name));

        var pick = new Button { Content = "Choose image" };
        var clear = new Button { Content = "Remove", Margin = new Thickness(8, 0, 0, 0) };
        pick.Click += (_, _) =>
        {
            var dlg = new OpenFileDialog { Filter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.webp|All files|*.*" };
            if (dlg.ShowDialog() == true) gs.ProfileImagePath = dlg.FileName;
        };
        clear.Click += (_, _) => gs.ProfileImagePath = "";
        var pp = new StackPanel { Orientation = Orientation.Horizontal };
        pp.Children.Add(pick);
        pp.Children.Add(clear);
        page.Children.Add(UiKit.Row("Profile image", "A square image works best.", pp));

        // Cards
        var cards = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        cards.Children.Add(new TextBlock { Text = "Home cards", Style = (Style)Application.Current.FindResource("Title"), Margin = new Thickness(0, 0, 0, 4) });
        cards.Children.Add(new TextBlock { Text = "Hidden cards keep their slot and return to it when shown again.", Style = (Style)Application.Current.FindResource("Muted"), Margin = new Thickness(0, 0, 0, 12) });
        foreach (var c in layout.Ordered)
        {
            var id = c.Id;
            cards.Children.Add(UiKit.Row(c.Title, null, UiKit.Toggle(layout.IsVisible(id), v => layout.SetVisible(id, v))));
        }
        page.Children.Add(cards);
        return page;
    }
}
