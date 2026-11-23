using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using Calc.Core;

namespace Calc.Windows;

/// <summary>The hover card under a result. It is a passive surface inside a restyled ToolTip, so WPF still owns
/// show/hide timing, keyboard-focus display and dismissal. The popup lives outside the window's resource tree,
/// so the owner applies theme brushes each time the card opens.</summary>
internal sealed class ResultCard : Border
{
    /// <summary>Transparent space around the card that holds its shadow; placement offsets by it.</summary>
    public static readonly Thickness ShadowSpace = new(12, 2, 12, 16);
    private readonly List<(DependencyObject Target, DependencyProperty Property, string Key)> themed = [];
    private readonly TranslateTransform slide = new();
    private readonly DropShadowEffect shadow = new() { BlurRadius = 18, ShadowDepth = 4, Direction = 270, Color = Colors.Black };

    /// <summary>Plain text of everything the card shows, for automation and diagnostics.</summary>
    public string Text { get; }

    private ResultCard(UIElement body, string text, FontFamily family)
    {
        Text = text;
        Margin = ShadowSpace; Padding = new Thickness(12, 9, 12, 10); MaxWidth = 340;
        CornerRadius = new CornerRadius(8); BorderThickness = new Thickness(1);
        Effect = shadow; RenderTransform = slide; SnapsToDevicePixels = true; UseLayoutRounding = true;
        TextElement.SetFontFamily(this, family); TextElement.SetFontSize(this, 13);
        Theme(this, BackgroundProperty, "SurfaceRaisedBrush"); Theme(this, BorderBrushProperty, "StrokeBrush");
        Theme(this, TextElement.ForegroundProperty, "TextPrimaryBrush");
        AutomationProperties.SetName(this, text);
        Child = body;
    }

    public static ResultCard Problem(string message, FontFamily family)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var icon = new TextBlock { Text = "", FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 14,
            Margin = new Thickness(0, 1, 9, 0), VerticalAlignment = VerticalAlignment.Top };
        var text = new TextBlock { Text = Unbroken(message), TextWrapping = TextWrapping.Wrap, LineHeight = 19 };
        Grid.SetColumn(text, 1); grid.Children.Add(icon); grid.Children.Add(text);
        var card = new ResultCard(grid, message, family);
        card.Theme(icon, TextBlock.ForegroundProperty, "WarningBrush");
        return card;
    }

    /// <summary>Headline is the exact held value when the row shows something else; rows replace the note for breakdowns.</summary>
    public static ResultCard? Explain(string? headline, string note, PayrollBreakdown? breakdown, string sources, FontFamily family)
    {
        if (string.IsNullOrEmpty(headline) && note.Length == 0 && breakdown is null && sources.Length == 0) return null;
        var stack = new StackPanel(); var parts = new List<string>();
        var muted = new List<TextBlock>(); var strong = new List<TextBlock>(); var dividers = new List<Border>();
        void Section(UIElement element) { if (stack.Children.Count > 0 && element is FrameworkElement framed) framed.Margin = new Thickness(0, 6, 0, 0); stack.Children.Add(element); }
        if (!string.IsNullOrEmpty(headline))
        {
            var block = Tabular(new TextBlock { Text = headline, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            Section(block); parts.Add(headline);
        }
        if (breakdown is not null)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            foreach (var row in breakdown.Rows)
            {
                var r = grid.RowDefinitions.Count;
                if (row.Kind == PayrollBreakdownRowKind.Total)
                {
                    grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                    var rule = new Border { Height = 1, Margin = new Thickness(0, 5, 0, 4) };
                    Grid.SetRow(rule, r); Grid.SetColumnSpan(rule, 2); grid.Children.Add(rule); dividers.Add(rule); r++;
                }
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var label = new TextBlock { Text = row.Label, Margin = new Thickness(0, 1, 24, 1) };
                var amount = Tabular(new TextBlock { Text = row.Amount, Margin = new Thickness(0, 1, 0, 1), HorizontalAlignment = HorizontalAlignment.Right });
                Grid.SetRow(label, r); Grid.SetRow(amount, r); Grid.SetColumn(amount, 1);
                grid.Children.Add(label); grid.Children.Add(amount);
                switch (row.Kind)
                {
                    case PayrollBreakdownRowKind.Total:
                        label.FontWeight = amount.FontWeight = FontWeights.SemiBold; strong.Add(label); strong.Add(amount); break;
                    case PayrollBreakdownRowKind.Deduction or PayrollBreakdownRowKind.Credit: muted.Add(label); break;
                    case PayrollBreakdownRowKind.Info:
                        label.Margin = amount.Margin = new Thickness(label.Margin.Left, 4, label.Margin.Right, 0);
                        label.FontSize = amount.FontSize = 12; muted.Add(label); muted.Add(amount); break;
                }
                parts.Add(row.Label + " " + row.Amount);
            }
            Section(grid);
            note = breakdown.Footer ?? "";
        }
        if (note.Length > 0) { var block = new TextBlock { Text = Unbroken(note), TextWrapping = TextWrapping.Wrap, LineHeight = 19 }; Section(block); parts.Add(note); if (breakdown is not null) muted.Add(block); }
        if (sources.Length > 0) { var block = new TextBlock { Text = sources, FontSize = 12, TextWrapping = TextWrapping.Wrap }; Section(block); if (note.Length > 0) block.Margin = new Thickness(0, 2, 0, 0); muted.Add(block); parts.Add(sources); }
        var card = new ResultCard(stack, string.Join("\n", parts), family);
        foreach (var block in muted) card.Theme(block, TextBlock.ForegroundProperty, "TextSecondaryBrush");
        foreach (var block in strong) card.Theme(block, TextBlock.ForegroundProperty, "AccentBrush");
        foreach (var rule in dividers) card.Theme(rule, BackgroundProperty, "StrokeBrush");
        return card;
    }

    /// <summary>Keeps digit groups ("34 946 044") and slash units ("x/year") on one line.</summary>
    private static readonly string NoBreakSpace = ((char)0x00A0).ToString(), SlashJoined = "/" + (char)0x2060;
    private static string Unbroken(string text) => Regex.Replace(text, @"(?<=\d) (?=\d{3}\b)", NoBreakSpace).Replace("/", SlashJoined);
    private static TextBlock Tabular(TextBlock block) { Typography.SetNumeralAlignment(block, FontNumeralAlignment.Tabular); return block; }
    private void Theme(DependencyObject target, DependencyProperty property, string key) => themed.Add((target, property, key));

    /// <summary>Applies current brushes and plays a short settle-in: fade and a 4 px drop, skipped when the OS turns off client animation.</summary>
    public void Open(Func<string, object?> resource, bool dark, bool contrast)
    {
        foreach (var (target, property, key) in themed) if (resource(key) is Brush brush) target.SetValue(property, brush);
        Effect = contrast ? null : shadow; shadow.Opacity = dark ? .45 : .14;
        if (!SheetMotion.Enabled) { BeginAnimation(OpacityProperty, null); slide.BeginAnimation(TranslateTransform.YProperty, null); Opacity = 1; slide.Y = 0; return; }
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut }; var time = TimeSpan.FromMilliseconds(140);
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, time) { EasingFunction = ease });
        slide.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-4, 0, time) { EasingFunction = ease });
    }
}
