using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
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
    public static Grid Row(string label, string? hint, FrameworkElement control) => CreateRow(label, hint, control, grouped: false);

    /// <summary>A padded row for a SettingsGroup, with readable secondary text.</summary>
    public static Grid SettingsRow(string label, string? hint, FrameworkElement control) => CreateRow(label, hint, control, grouped: true);

    static Grid CreateRow(string label, string? hint, FrameworkElement control, bool grouped)
    {
        var g = new Grid { Margin = grouped ? new Thickness(16, 10, 16, 10) : new Thickness(0, 0, 0, 16), MinHeight = grouped ? 24 : 0 };
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 24, 0) };
        left.Children.Add(new TextBlock { Text = label, FontSize = 13 });
        if (hint is not null) left.Children.Add(new TextBlock { Text = hint, Style = Res<Style>(grouped ? "Caption" : "Muted"), FontSize = grouped ? 12 : 11, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
        control.VerticalAlignment = VerticalAlignment.Center;
        // The row's label names its control, and the unnamed inputs of a small group (a slider next to its value, a box next to its button).
        if (string.IsNullOrEmpty(AutomationProperties.GetName(control))) AutomationProperties.SetName(control, label);
        if (control is Panel group)
            foreach (var input in group.Children.OfType<Control>())
                if (input is System.Windows.Controls.Primitives.RangeBase or System.Windows.Controls.Primitives.TextBoxBase or PasswordBox or ComboBox
                    && string.IsNullOrEmpty(AutomationProperties.GetName(input))) AutomationProperties.SetName(input, label);
        Grid.SetColumn(control, 1);
        g.Children.Add(left);
        g.Children.Add(control);
        return g;
    }

    /// <summary>Rounded settings group with inset separators. Rows own their padding.</summary>
    public static StackPanel SettingsGroup(IEnumerable<FrameworkElement> rows, string? title = null, string? footer = null)
    {
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 20) };
        if (title is not null)
        {
            var heading = Text(title, "Title");
            heading.Margin = new Thickness(4, 0, 0, 8);
            outer.Children.Add(heading);
        }
        var content = new StackPanel();
        foreach (var row in rows)
        {
            if (content.Children.Count > 0)
            {
                var separator = new Border { Height = 1, Margin = new Thickness(16, 0, 16, 0) };
                separator.SetResourceReference(Border.BackgroundProperty, "StrokeBrush");
                content.Children.Add(separator);
            }
            content.Children.Add(row);
        }
        var box = new Border { CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1), Child = content };
        box.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        box.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        outer.Children.Add(box);
        if (footer is not null)
        {
            var note = Text(footer);
            note.FontSize = 12;
            note.Margin = new Thickness(4, 8, 4, 0);
            outer.Children.Add(note);
        }
        return outer;
    }

    public static TextBlock SettingsIntro(string text) => new()
    {
        Text = text, Style = Res<Style>("Caption"), FontSize = 12,
        TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -4, 0, 20)
    };

    /// <summary>One-way binding from <paramref name="source"/>.<paramref name="path"/> (no DataContext needed). Works for elements, Runs and brushes.</summary>
    public static T Bind<T>(T target, DependencyProperty property, object source, string path, IValueConverter? converter = null) where T : DependencyObject
    {
        BindingOperations.SetBinding(target, property, new Binding(path) { Source = source, Mode = BindingMode.OneWay, Converter = converter });
        return target;
    }

    /// <summary>Visible while the bool property <paramref name="path"/> of <paramref name="source"/> is true, otherwise Collapsed.</summary>
    public static T BindVisible<T>(T target, object source, string path) where T : UIElement =>
        Bind(target, UIElement.VisibilityProperty, source, path, Res<IValueConverter>("BoolToVis"));

    public static CheckBox Toggle() => new() { Style = Res<Style>("ToggleSwitch") };

    /// <summary>A toggle switch showing <paramref name="value"/>; <paramref name="set"/> is called on every change.</summary>
    public static CheckBox Toggle(bool value, Action<bool> set)
    {
        var t = Toggle();
        t.IsChecked = value;
        t.Checked += (_, _) => set(true);
        t.Unchecked += (_, _) => set(false);
        return t;
    }

    /// <summary>Vertical page container with standard padding for a settings section.</summary>
    public static StackPanel Page(string title)
    {
        var p = new StackPanel { Margin = new Thickness(28, 24, 28, 24) };
        p.Children.Add(Header(title));
        return p;
    }
}
