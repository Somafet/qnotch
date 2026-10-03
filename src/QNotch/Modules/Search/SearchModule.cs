using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Search;

/// <summary>
/// One search box over everything the other modules registered in <c>ctx.Search</c>, plus tabs and settings pages.
/// Costs nothing while idle: sources are asked on each keystroke and only filter what they already hold in memory.
/// </summary>
public sealed class SearchModule : INotchModule, ICadenceAware
{
    const string Id = "search", Glyph = "";
    const int PerSource = 5;

    ModuleContext _ctx = null!;
    TextBox? _box;
    ListBox _list = null!;
    FrameworkElement _hint = null!;
    TextBlock _none = null!, _about = null!;
    Shell.Shortcut _key = null!;

    public void Initialize(ModuleContext ctx)
    {
        _ctx = ctx;
        ctx.Tabs.Register(new TabDescriptor(Id, "Search", Glyph, 5, View));
        ctx.Search.Register(new SearchSource("tabs", "Tabs","", 80, q => ctx.Tabs.Items
            .Where(t => t.Id != Id && t.Title.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(t => new SearchHit(t.Title, "", () => ctx.Shell.SelectTab(t.Id)))));
        ctx.Search.Register(new SearchSource("settings", "Settings", Glyphs.Settings, 90, q => ctx.SettingsSections.Items
            .Where(s => s.Title.Contains(q, StringComparison.OrdinalIgnoreCase))
            .Select(s => new SearchHit(s.Title, "", () => ctx.Shell.OpenSettings(s.Id)))));
        ctx.Shell.TabChanged += id => { if (id == Id) _box?.Focus(); }; // typing works at once when the window has the keyboard
        _key = ctx.Shortcuts.Add(Id, "Open search", "Opens the Search tab with the cursor in the box.", "Ctrl+Alt+F", Summon, 20);
        ctx.Shortcuts.Changed += About;
    }

    /// <summary>The empty state names where search looks and the current shortcut.</summary>
    void About()
    {
        if (_box is null) return;
        var places = string.Join(", ", _ctx.Search.Items.Select(s => s.Title));
        _about.Text = $"Looks in: {places}." + (_key.Gesture.Length > 0 && !_key.Taken ? $" {_key.Gesture} opens this from anywhere." : "");
    }

    /// <summary>Panel closed: the next search starts empty.</summary>
    public void SetCadence(Cadence cadence)
    {
        if (cadence == Cadence.Slow && !_ctx.Settings.ReadOnly) _box?.Clear();
    }

    void Summon()
    {
        if (_box is { IsKeyboardFocused: true } && _ctx.Shell.ActiveTab == Id) { _ctx.Shell.ClosePanel(); return; }
        if (!_ctx.Shell.OpenPanelWithKeyboard(Id)) return;
        _ctx.Dispatcher.BeginInvoke(() => { Keyboard.Focus(_box); _box?.SelectAll(); });
    }

    FrameworkElement View()
    {
        var box = _box = new TextBox { FontSize = 13, Padding = new Thickness(17, 4, 5, 4), MaxLength = 200 }; // the content host adds the padding once more
        System.Windows.Automation.AutomationProperties.SetName(box, "Search");
        var icon = UiKit.Glyph(Glyph, 14, "TextTertiaryBrush");
        icon.Margin = new Thickness(12, 0, 0, 0);
        var prompt = new TextBlock { Text = "Search", FontSize = 13, Margin = new Thickness(37, 0, 0, 0) };
        prompt.SetResourceReference(TextBlock.ForegroundProperty, "TextTertiaryBrush");
        foreach (var t in new[] { icon, prompt }) { t.VerticalAlignment = VerticalAlignment.Center; t.HorizontalAlignment = HorizontalAlignment.Left; t.IsHitTestVisible = false; }
        var top = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        top.Children.Add(box);
        top.Children.Add(icon);
        top.Children.Add(prompt);

        // Never focusable: the keyboard stays in the box, arrows and Enter are handled there.
        _list = new ListBox { Focusable = false, Padding = new Thickness(0, 0, 0, 12) };
        var hint = (StackPanel)(_hint = Placeholder.Create(Glyph, "Search QNotch", ""));
        _about = (TextBlock)hint.Children[^1];
        About();
        _none = UiKit.Text("", "Muted");
        _none.HorizontalAlignment = HorizontalAlignment.Center;
        _none.Margin = new Thickness(0, 24, 0, 0);

        var root = new Grid { Margin = new Thickness(19, 2, 19, 0) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());
        root.Children.Add(top);
        foreach (var e in new[] { _list, _hint, _none }) { Grid.SetRow(e, 1); root.Children.Add(e); }

        box.TextChanged += (_, _) => { prompt.Visibility = box.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; Find(box.Text.Trim()); };
        box.PreviewKeyDown += OnKey;
        if (_ctx.Settings.ReadOnly) box.Text = "clip"; // snapshot run: show results
        else Find("");
        return root;
    }

    void Find(string q)
    {
        _list.Items.Clear();
        if (q.Length > 0)
            foreach (var src in _ctx.Search.Items)
            {
                try { foreach (var hit in src.Find(q).Take(PerSource)) _list.Items.Add(Row(src, hit)); }
                catch (Exception ex) { Log.Error($"Search source '{src.Id}' failed", ex); }
            }
        var any = _list.Items.Count > 0;
        if (any) _list.SelectedIndex = 0;
        _none.Text = $"Nothing matches \"{q}\".";
        _list.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        _hint.Visibility = q.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        _none.Visibility = q.Length > 0 && !any ? Visibility.Visible : Visibility.Collapsed;
    }

    ListBoxItem Row(SearchSource src, SearchHit hit)
    {
        var glyph = UiKit.Glyph(src.Glyph, 14, "AccentBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var tile = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Child = glyph, Margin = new Thickness(0, 0, 10, 0) };
        tile.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        DockPanel.SetDock(tile, Dock.Left);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = hit.Title, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis });
        var sub = UiKit.Text(hit.Subtitle.Length > 0 ? $"{src.Title} · {hit.Subtitle}" : src.Title, "Muted");
        sub.TextWrapping = TextWrapping.NoWrap;
        sub.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(sub);

        var row = new DockPanel();
        row.Children.Add(tile);
        row.Children.Add(text);
        var item = new ListBoxItem { Content = row, Tag = hit, Focusable = false, Cursor = Cursors.Hand, Padding = new Thickness(8, 5, 8, 5) };
        item.PreviewMouseLeftButtonUp += (_, _) => Run(hit);
        return item;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        var n = _list.Items.Count;
        if (n == 0 || e.Key is not (Key.Down or Key.Up or Key.Enter)) return;
        e.Handled = true;
        if (e.Key == Key.Enter) { if (_list.SelectedItem is ListBoxItem { Tag: SearchHit hit }) Run(hit); return; }
        _list.SelectedIndex = Math.Clamp(_list.SelectedIndex + (e.Key == Key.Down ? 1 : -1), 0, n - 1);
        _list.ScrollIntoView(_list.SelectedItem);
    }

    static void Run(SearchHit hit)
    {
        try { hit.Run(); }
        catch (Exception ex) { Log.Error("Search action failed", ex); }
    }
}
