using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell;

/// <summary>
/// The drop screen (spec/drop-screen.md): while files are dragged over the notch it covers the panel and lists every place they can go,
/// grouped by drop source. Only a tile takes the drop; the rest of the screen refuses it. Built in code on first use.
/// </summary>
internal sealed class DropScreen : Grid
{
    const double TileWidth = 160, TileGap = 8;

    readonly Registry<DropSourceDescriptor> _sources;
    readonly TextBlock _title = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly StackPanel _groups = new();
    readonly ContentControl _empty = new() { Focusable = false };
    IReadOnlyList<string> _files = [];
    string _shown = "";
    readonly System.Windows.Threading.DispatcherTimer _recheck;

    /// <summary>A tile took the drop: the target and the dropped paths. The screen is already hidden.</summary>
    public event Action<DropTarget, string[]>? Dropped;
    /// <summary>The screen appeared (true) or went away (false).</summary>
    public event Action<bool>? ShownChanged;

    public DropScreen(Registry<DropSourceDescriptor> sources)
    {
        _sources = sources;
        // Sources learn their state while the screen shows (a refresh that started with the drag): ask again, rebuild only on change.
        _recheck = new System.Windows.Threading.DispatcherTimer(System.Windows.Threading.DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(400) };
        _recheck.Tick += (_, _) => Build();
        Visibility = Visibility.Collapsed;
        AllowDrop = true;
        SetResourceReference(BackgroundProperty, "SurfaceBrush");
        AutomationProperties.SetAutomationId(this, "drop-screen");
        AutomationProperties.SetName(this, "Drop files");
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(70) });
        RowDefinitions.Add(new RowDefinition());

        var hint = UiKit.Text("Choose where they go", "Muted");
        hint.Margin = new Thickness(0, 3, 0, 0);
        var header = new StackPanel { Margin = new Thickness(23, 18, 23, 0), VerticalAlignment = VerticalAlignment.Top };
        header.Children.Add(_title);
        header.Children.Add(hint);
        Children.Add(header);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Content = _groups, Margin = new Thickness(23, 0, 17, 14) };
        SetRow(scroll, 1);
        SetRow(_empty, 1);
        Children.Add(scroll);
        Children.Add(_empty);

        // Anywhere but a tile: no drop. Tiles mark their own events handled first.
        void Refuse(object? _, DragEventArgs e)
        {
            if (e.Handled) return;
            e.Effects = DragDropEffects.None;
            e.Handled = true;
        }
        DragEnter += Refuse;
        DragOver += Refuse;
        Drop += (_, e) => e.Handled = true;
    }

    public bool IsShown => Visibility == Visibility.Visible;
    public int FileCount => _files.Count;

    /// <summary>Asks every source for its targets for <paramref name="files"/> and shows them.</summary>
    public void Show(IReadOnlyList<string> files)
    {
        _files = files;
        _title.Text = files.Count switch
        {
            0 => "Drop files",
            1 => $"Drop {FileName(files[0])}",
            _ => $"Drop {files.Count} items",
        };
        _shown = "";
        Build();
        var was = IsShown;
        Visibility = Visibility.Visible;
        _recheck.Start();
        if (!was) ShownChanged?.Invoke(true);
    }

    /// <summary>Asks every source again; rebuilds the tiles only when a target appeared, went or changed.</summary>
    void Build()
    {
        var lists = new List<(DropSourceDescriptor Source, IReadOnlyList<DropTarget> Targets)>();
        foreach (var source in _sources.Items)
        {
            try { if (source.Targets(_files) is { Count: > 0 } targets) lists.Add((source, targets)); }
            catch (Exception ex) { Log.Error($"Drop source '{source.Id}' failed", ex); }
        }
        var key = string.Join('\n', lists.SelectMany(l => l.Targets.Select(t => $"{l.Source.Id}|{t.Id}|{t.Title}|{t.Subtitle}|{t.Glyph}|{t.Enabled}")));
        if (key == _shown && _groups.Children.Count + (_empty.Content is null ? 0 : 1) > 0) return;
        _shown = key;
        _groups.Children.Clear();
        foreach (var (source, targets) in lists) _groups.Children.Add(Group(source, targets));
        _empty.Content = lists.Count == 0 ? Placeholder.Create("", "", "Nothing can take these files right now.") : null;
        _empty.Visibility = lists.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Hide()
    {
        if (!IsShown) return;
        _recheck.Stop();
        Visibility = Visibility.Collapsed;
        _groups.Children.Clear();
        _files = [];
        ShownChanged?.Invoke(false);
    }

    static string FileName(string path)
    {
        var n = System.IO.Path.GetFileName(path.TrimEnd('\\', '/'));
        return n.Length > 0 ? n : path;
    }

    FrameworkElement Group(DropSourceDescriptor source, IReadOnlyList<DropTarget> targets)
    {
        var glyph = UiKit.Glyph(source.Glyph, 12, "TextSecondaryBrush");
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var title = new TextBlock { Text = source.Title, FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(6, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        title.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(2, 0, 0, 8) };
        heading.Children.Add(glyph);
        heading.Children.Add(title);
        var tiles = new WrapPanel();
        foreach (var t in targets) tiles.Children.Add(Tile(source, t));
        var group = new StackPanel { Margin = new Thickness(0, 0, 0, 6) };
        group.Children.Add(heading);
        group.Children.Add(tiles);
        return group;
    }

    FrameworkElement Tile(DropSourceDescriptor source, DropTarget target)
    {
        var glyph = UiKit.Glyph(target.Glyph, 20, target.Enabled ? "TextPrimaryBrush" : "TextTertiaryBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Left;
        var name = new TextBlock { Text = target.Title, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 8, 0, 0) };
        name.SetResourceReference(TextBlock.ForegroundProperty, target.Enabled ? "TextPrimaryBrush" : "TextSecondaryBrush");
        var content = new StackPanel { Width = TileWidth - 27 };
        content.Children.Add(glyph);
        content.Children.Add(name);
        if (target.Subtitle is { Length: > 0 } sub)
        {
            var subtitle = new TextBlock { Text = sub, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0) };
            subtitle.SetResourceReference(TextBlock.ForegroundProperty, target.Enabled ? "TextSecondaryBrush" : "TextTertiaryBrush");
            content.Children.Add(subtitle);
        }
        // A button for its role, name and enabled state; it is never clicked (the screen only shows during a drag).
        var tile = new Button { Content = content, Padding = new Thickness(12, 10, 12, 10), Focusable = false, IsEnabled = target.Enabled };
        AutomationProperties.SetAutomationId(tile, $"drop-{source.Id}-{target.Id}");
        AutomationProperties.SetName(tile, $"{target.Title}, {source.Title}");
        if (target.Subtitle is { Length: > 0 }) AutomationProperties.SetHelpText(tile, target.Subtitle);
        var frame = new Border
        {
            Child = tile, Width = TileWidth, CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1.5),
            Margin = new Thickness(0, 0, TileGap, TileGap), BorderBrush = Brushes.Transparent, AllowDrop = true,
        };
        if (!target.Enabled) return frame; // a disabled button takes no drag events: the screen refuses the drop
        void Light(bool on)
        {
            if (on) frame.SetResourceReference(Border.BorderBrushProperty, "AccentBrush");
            else frame.BorderBrush = Brushes.Transparent;
        }
        void Over(object? _, DragEventArgs e)
        {
            var ok = e.Data.GetDataPresent(DataFormats.FileDrop);
            e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
            Light(ok);
        }
        frame.DragEnter += Over;
        frame.DragOver += Over;
        frame.DragLeave += (_, _) => Light(false);
        frame.Drop += (_, e) =>
        {
            e.Handled = true;
            Light(false);
            if (e.Data.GetData(DataFormats.FileDrop) is not string[] files || files.Length == 0) return;
            Hide();
            Dropped?.Invoke(target, files);
        };
        return frame;
    }
}
