using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace QNotch.Theme;

/// <summary>Code-side helpers for building consistent panels and settings sections without repeating XAML.</summary>
public static class UiKit
{
    static T Res<T>(string key) => (T)Application.Current.FindResource(key);

    /// <summary>Text with one of the named styles: Title, Caption, Muted.</summary>
    public static TextBlock Text(string text, string style = "Caption") =>
        new() { Text = text, Style = Res<Style>(style), TextWrapping = TextWrapping.Wrap };

    public static TextBlock Glyph(string glyph, double size = 16, string brushKey = "TextSecondaryBrush")
    {
        var t = new TextBlock { Text = glyph, Style = Res<Style>("Glyph"), FontSize = size };
        t.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
        return t;
    }

    /// <summary>Section heading for a settings page.</summary>
    public static TextBlock Header(string text) => new() { Text = text, Style = Res<Style>("Title"), FontSize = 20, Margin = new Thickness(0, 0, 0, 16) };

    /// <summary>A settings row: label and optional hint on the left, control on the right.</summary>
    public static Grid Row(string label, string? hint, FrameworkElement control)
    {
        var g = new Grid { Margin = new Thickness(0, 0, 0, 16) };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 24, 0) };
        left.Children.Add(new TextBlock { Text = label, FontSize = 13 });
        if (hint is not null) left.Children.Add(new TextBlock { Text = hint, Style = Res<Style>("Muted"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        g.Children.Add(left);
        g.Children.Add(control);
        return g;
    }

    public static CheckBox Toggle() => new() { Style = Res<Style>("ToggleSwitch") };

    /// <summary>Vertical page container with standard padding for a settings section.</summary>
    public static StackPanel Page(string title)
    {
        var p = new StackPanel { Margin = new Thickness(28, 24, 28, 24) };
        p.Children.Add(Header(title));
        return p;
    }
}
