using System.Windows;
using System.Windows.Controls;

namespace QNotch.Theme;

/// <summary>Explicit "empty / not built yet / unavailable" view used by stub modules and failed factories.</summary>
public static class Placeholder
{
    public static FrameworkElement Create(string glyph, string title, string message)
    {
        var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var g = UiKit.Glyph(glyph, 22, "TextTertiaryBrush");
        g.HorizontalAlignment = HorizontalAlignment.Center;
        sp.Children.Add(g);
        if (title.Length > 0)
            sp.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.FindResource("Title"), Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Center });
        var m = new TextBlock { Text = message, Style = (Style)Application.Current.FindResource("Muted"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0), MaxWidth = 300 };
        sp.Children.Add(m);
        return sp;
    }
}
