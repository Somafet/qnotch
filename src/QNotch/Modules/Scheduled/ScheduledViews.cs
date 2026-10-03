using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.Scheduled;

internal static class ScheduledUi
{
    public static string StateBrush(SchedTask t) => t.Failed ? "DangerBrush" : t.Enabled ? "AccentBrush" : "TextTertiaryBrush";

    /// <summary>A rounded row that lights up under the pointer.</summary>
    public static Border Hover(UIElement child, Thickness padding, Thickness margin, string? restBrush)
    {
        var b = new Border { CornerRadius = new CornerRadius(8), Padding = padding, Margin = margin, Child = child };
        void Rest() { if (restBrush is null) b.Background = Brushes.Transparent; else b.SetResourceReference(Border.BackgroundProperty, restBrush); }
        Rest();
        b.MouseEnter += (_, _) => b.SetResourceReference(Border.BackgroundProperty, restBrush is null ? "ControlBrush" : "ControlHoverBrush");
        b.MouseLeave += (_, _) => Rest();
        return b;
    }
}

/// <summary>Home card body: the first three tasks with their next run. A click opens the Scheduled tab.</summary>
internal sealed class ScheduledCard : Grid
{
    public ScheduledCard(ScheduledState st, IShell shell)
    {
        var rows = new StackPanel { VerticalAlignment = VerticalAlignment.Top };
        var empty = Placeholder.Create(ScheduledModule.Icon, "", "No scheduled tasks.");
        Children.Add(rows);
        Children.Add(empty);

        void Refresh()
        {
            rows.Children.Clear();
            foreach (var t in st.Items.Take(3))
            {
                var dot = UiKit.Glyph(ScheduledModule.Icon, 12, ScheduledUi.StateBrush(t));
                dot.VerticalAlignment = VerticalAlignment.Center;
                var when = UiKit.Text(t.Short, "Muted");
                when.VerticalAlignment = VerticalAlignment.Center;
                when.Margin = new Thickness(6, 0, 0, 0);
                DockPanel.SetDock(dot, Dock.Left);
                DockPanel.SetDock(when, Dock.Right);
                var name = new TextBlock { Text = t.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                name.SetResourceReference(TextBlock.ForegroundProperty, t.Enabled ? "TextPrimaryBrush" : "TextSecondaryBrush");
                var line = new DockPanel();
                line.Children.Add(dot);
                line.Children.Add(when);
                line.Children.Add(name);
                var b = ScheduledUi.Hover(line, new Thickness(6, 4, 6, 4), new Thickness(-6, 0, -6, 1), null);
                b.Cursor = Cursors.Hand;
                b.ToolTip = $"{t.Name}: {t.Meta}";
                b.MouseLeftButtonUp += (_, _) => shell.SelectTab(ScheduledModule.TabId);
                rows.Children.Add(b);
            }
            empty.Visibility = st.Loaded && st.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        st.Changed += Refresh;
        Refresh();
    }
}

/// <summary>The tab: every task with pause or resume and delete. Delete asks once more in the row.</summary>
internal sealed class ScheduledTab : Grid
{
    readonly ScheduledModule _module;
    readonly ScheduledState _st;
    readonly StackPanel _rows = new() { Margin = new Thickness(0, 0, 0, 12) };
    readonly TextBlock _error = UiKit.Text("", "Muted");
    readonly FrameworkElement _empty = Placeholder.Create(ScheduledModule.Icon, "No scheduled tasks", "Tasks you add to the Windows Task Scheduler show up here.");
    readonly FrameworkElement _unavailable = Placeholder.Create(Glyphs.Warning, "Task Scheduler unavailable", "The Windows Task Scheduler could not be read.");
    string? _confirm; // name of the task whose delete waits for a second click

    public ScheduledTab(ScheduledModule module, ScheduledState st)
    {
        _module = module;
        _st = st;
        Margin = new Thickness(19, 2, 19, 0);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition());
        _error.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
        _error.Margin = new Thickness(0, 0, 0, 6);
        Children.Add(_error);
        foreach (var e in new[] { new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Content = _rows }, _empty, _unavailable })
        {
            SetRow(e, 1);
            Children.Add(e);
        }
        st.Changed += () => { _confirm = null; Render(); };
        Render();
    }

    void Render()
    {
        _error.Text = _st.Error;
        _error.Visibility = _st.Error.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _unavailable.Visibility = _st.Unavailable ? Visibility.Visible : Visibility.Collapsed;
        _empty.Visibility = _st.Loaded && !_st.Unavailable && _st.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _rows.Children.Clear();
        if (_st.Unavailable) return;
        foreach (var t in _st.Items) _rows.Children.Add(Row(t));
    }

    UIElement Row(SchedTask t)
    {
        var icon = UiKit.Glyph(ScheduledModule.Icon, 14, ScheduledUi.StateBrush(t));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var tile = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Child = icon };
        tile.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");

        var name = new TextBlock { Text = t.Name, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
        name.SetResourceReference(TextBlock.ForegroundProperty, t.Enabled ? "TextPrimaryBrush" : "TextSecondaryBrush");
        var meta = UiKit.Text(t.Meta, "Muted");
        meta.TextWrapping = TextWrapping.NoWrap;
        meta.TextTrimming = TextTrimming.CharacterEllipsis;
        meta.Margin = new Thickness(0, 2, 0, 0);
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(name);
        text.Children.Add(meta);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        if (_confirm == t.Name)
        {
            var delete = TextButton("Delete", () => _module.Delete(t));
            delete.SetResourceReference(Control.ForegroundProperty, "DangerBrush");
            buttons.Children.Add(delete);
            buttons.Children.Add(TextButton("Cancel", () => { _confirm = null; Render(); }));
        }
        else
        {
            buttons.Children.Add(IconButton(t.Enabled ? Glyphs.Pause : Glyphs.Play, t.Enabled ? "Pause" : "Resume", () => _module.SetEnabled(t, !t.Enabled)));
            buttons.Children.Add(IconButton(Glyphs.Delete, "Delete", () => { _confirm = t.Name; Render(); }));
        }

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        SetColumn(text, 1);
        SetColumn(buttons, 2);
        g.Children.Add(tile);
        g.Children.Add(text);
        g.Children.Add(buttons);
        return ScheduledUi.Hover(g, new Thickness(10, 8, 10, 8), new Thickness(0, 0, 0, 4), "ControlBrush");
    }

    static Button IconButton(string glyph, string tip, Action click)
    {
        var b = new Button { Content = glyph, ToolTip = tip, Width = 26, Height = 26, Margin = new Thickness(4, 0, 0, 0), Style = (Style)Application.Current.FindResource("IconButton") };
        b.Click += (_, _) => click();
        return b;
    }

    static Button TextButton(string label, Action click)
    {
        var b = new Button { Content = label, Padding = new Thickness(10, 4, 10, 4), FontSize = 12, Margin = new Thickness(6, 0, 0, 0) };
        b.Click += (_, _) => click();
        return b;
    }
}
