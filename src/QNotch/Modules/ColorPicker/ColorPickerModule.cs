using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.ColorPicker;

public sealed class ColorPickerSettings { public List<string> Recent { get; set; } = []; }

/// <summary>
/// Eyedropper card: pick a color anywhere on screen, its hex code goes to the clipboard and into a short list of recent colors.
/// Costs nothing until a pick starts (see <see cref="ScreenPick"/>).
/// </summary>
public sealed class ColorPickerModule : INotchModule
{
    const string Id = "colorpicker";
    const int Max = 6; // one row of swatches on the card

    ModuleContext _ctx = null!;
    ColorPickerSettings _s = null!;
    event Action? Changed;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        _s = ctx.Settings.Get<ColorPickerSettings>(Id);
        if (ctx.Settings.ReadOnly) _s = new() { Recent = ["#4ADE80", "#1ED760", "#FF0000", "#3B82F6", "#F59E0B"] }; // snapshot run: demo colors
        ctx.Cards.Register(new CardDescriptor(Id, "Color picker", 27, Card));
    }

    void Pick()
    {
        if (_ctx.Settings.ReadOnly || ScreenPick.Active) return;
        _ctx.Shell.ClosePanel(); // out of the way, so what is under the notch can be picked too
        _ctx.Hotkeys.Register(ModifierKeys.None, Key.Escape, ScreenPick.Cancel);
        ScreenPick.Start(c =>
        {
            _ctx.Hotkeys.Unregister(ModifierKeys.None, Key.Escape);
            if (c is { } color) Use(ScreenPick.Hex(color));
        });
    }

    /// <summary>Copies the hex code and moves it to the front of the recent list.</summary>
    void Use(string hex)
    {
        try { System.Windows.Clipboard.SetText(hex); }
        catch (Exception ex) { Log.Warn("Color copy failed", ex); }
        _s.Recent.Remove(hex);
        _s.Recent.Insert(0, hex);
        if (_s.Recent.Count > Max) _s.Recent.RemoveRange(Max, _s.Recent.Count - Max);
        if (!_ctx.Settings.ReadOnly) _ctx.Settings.Save(Id, _s);
        Changed?.Invoke();
    }

    FrameworkElement Card()
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = UiKit.Glyph("", 13, "TextPrimaryBrush");
        glyph.VerticalAlignment = VerticalAlignment.Center;
        glyph.Margin = new Thickness(0, 0, 8, 0);
        label.Children.Add(glyph);
        label.Children.Add(new TextBlock { Text = "Pick a color", FontSize = 12 });
        var pick = new Button { Content = label, ToolTip = "Left click picks, right click or Esc cancels" };
        pick.Click += (_, _) => Pick();

        var recent = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        var empty = UiKit.Text("Picked colors show up here. Click one to copy it again.", "Muted");
        empty.Margin = new Thickness(0, 10, 0, 0);

        var root = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        root.Children.Add(pick);
        root.Children.Add(recent);
        root.Children.Add(empty);

        void Refresh()
        {
            recent.Children.Clear();
            foreach (var hex in _s.Recent) if (Swatch(hex) is { } s) recent.Children.Add(s);
            recent.Visibility = recent.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            empty.Visibility = recent.Children.Count > 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        Changed += Refresh;
        Refresh();
        return root;
    }

    UIElement? Swatch(string hex)
    {
        Color c;
        try { c = (Color)ColorConverter.ConvertFromString(hex); }
        catch { return null; } // hand-edited settings file
        var fill = new SolidColorBrush(c);
        fill.Freeze();
        var b = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(6), Margin = new Thickness(0, 0, 5, 0), Background = fill, BorderThickness = new Thickness(1), Cursor = Cursors.Hand, ToolTip = $"Copy {hex}" };
        b.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        b.MouseEnter += (_, _) => b.SetResourceReference(Border.BorderBrushProperty, "TextPrimaryBrush");
        b.MouseLeave += (_, _) => b.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        b.MouseLeftButtonUp += (_, _) => Use(hex);
        return b;
    }
}
