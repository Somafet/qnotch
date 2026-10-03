using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Clipboard;

/// <summary>Home card body: the three most recent entries, one line each. A click copies the entry again. Redraws only when the history changes.</summary>
internal sealed class ClipboardCard : Grid
{
    readonly ClipboardModule _module;
    readonly ClipboardState _st;
    readonly StackPanel _rows = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly FrameworkElement _empty = Placeholder.Create(Glyphs.Clipboard, "", "Nothing copied yet.");
    readonly FrameworkElement _unavailable = Placeholder.Create(Glyphs.Warning, "", "Clipboard unavailable.");

    public ClipboardCard(ClipboardModule module, ClipboardState st)
    {
        _module = module;
        _st = st;
        Children.Add(_rows);
        Children.Add(_empty);
        Children.Add(_unavailable);
        st.Entries.CollectionChanged += (_, _) => Refresh();
        st.PropertyChanged += (_, e) => { if (e.PropertyName is nameof(ClipboardState.Flash) or nameof(ClipboardState.IsAvailable)) Refresh(); };
        Refresh();
    }

    void Refresh()
    {
        _rows.Children.Clear();
        foreach (var e in _st.Entries.Take(3)) _rows.Children.Add(Row(e));
        _unavailable.Visibility = _st.IsAvailable ? Visibility.Collapsed : Visibility.Visible;
        _empty.Visibility = _st.IsAvailable && _st.Entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _rows.Visibility = _st.IsAvailable && _st.Entries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    UIElement Row(ClipEntry e)
    {
        var line = new DockPanel();
        var g = UiKit.Glyph(e.JustCopied ? Glyphs.Accept : e.Glyph, 12, e.JustCopied ? "SuccessBrush" : "TextTertiaryBrush");
        g.Width = 14;
        g.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(g, Dock.Left);
        var t = new TextBlock { Text = e.Line, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        t.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        line.Children.Add(g);
        line.Children.Add(t);

        var b = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(6, 4, 6, 4), Margin = new Thickness(-6, 0, -6, 1), Background = System.Windows.Media.Brushes.Transparent, Cursor = Cursors.Hand, Child = line, ToolTip = "Copy again", ContextMenu = _module.RowMenu(e) };
        b.MouseEnter += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        b.MouseLeave += (_, _) => b.Background = System.Windows.Media.Brushes.Transparent;
        b.MouseLeftButtonUp += (_, _) => _module.CopyAgain(e);
        return b;
    }
}
