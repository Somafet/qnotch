using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.Taildrop;

internal static class TaildropUi
{
    public static string DeviceGlyph(TaildropDevice d) => d.Os.ToLowerInvariant() switch
    {
        "ios" when d.Name.Contains("ipad", StringComparison.OrdinalIgnoreCase) => "",
        "ios" or "android" => "",
        "macos" => "",
        "windows" => "",
        _ => "",
    };

    public static string OsName(string os) => os.ToLowerInvariant() switch
    {
        "ios" => "iOS", "android" => "Android", "macos" => "macOS", "windows" => "Windows", "linux" => "Linux", "" => "", _ => os,
    };

    /// <summary>Lets the user pick files to send to <paramref name="device"/>; the panel stays open while the dialog shows.</summary>
    public static void Pick(TaildropModule module, IShell shell, TaildropDevice device)
    {
        var dlg = new OpenFileDialog { Multiselect = true, Title = $"Send files to {device.Name}" };
        bool ok;
        using (shell.HoldOpen()) ok = dlg.ShowDialog() == true;
        if (ok) module.Send(device, dlg.FileNames);
    }

    public static Button TextButton(string label, Action click, string? tip = null, bool accent = false)
    {
        var b = new Button { Content = label, Padding = new Thickness(10, 4, 10, 4), FontSize = 12, Margin = new Thickness(6, 0, 0, 0), ToolTip = tip };
        if (accent) b.Style = (Style)Application.Current.FindResource("AccentButton");
        b.Click += (_, _) => click();
        return b;
    }

    public static Button IconButton(string glyph, string tip, Action click)
    {
        var b = new Button { Content = glyph, ToolTip = tip, Width = 26, Height = 26, Margin = new Thickness(4, 0, 0, 0), Style = (Style)Application.Current.FindResource("IconButton") };
        b.Click += (_, _) => click();
        return b;
    }

    /// <summary>A thin bar that fills to <c>value</c> (0..1).</summary>
    public static (Grid Bar, Action<double> Set) Bar()
    {
        var g = new Grid { Height = 3 };
        var fill = new ColumnDefinition { Width = new GridLength(0, GridUnitType.Star) };
        var rest = new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) };
        g.ColumnDefinitions.Add(fill);
        g.ColumnDefinitions.Add(rest);
        var track = new Border { CornerRadius = new CornerRadius(1.5) };
        track.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        Grid.SetColumnSpan(track, 2);
        var done = new Border { CornerRadius = new CornerRadius(1.5) };
        done.SetResourceReference(Border.BackgroundProperty, "AccentBrush");
        g.Children.Add(track);
        g.Children.Add(done);
        return (g, v =>
        {
            v = Math.Clamp(v, 0, 1);
            fill.Width = new GridLength(v, GridUnitType.Star);
            rest.Width = new GridLength(1 - v, GridUnitType.Star);
        });
    }

    /// <summary>
    /// Turns <paramref name="target"/> into a drop target for one device: it lights up while files hover and sends them on drop. The drag
    /// events are handled here, so the shell's own file drop (the file tray) does not also take the files.
    /// </summary>
    public static void DropOn(FrameworkElement target, Border highlight, TaildropModule module, TaildropState st, Func<TaildropDevice> device)
    {
        target.AllowDrop = true;
        bool Accepts(DragEventArgs e) => e.Data.GetDataPresent(DataFormats.FileDrop) && device().Online && !st.Busy;
        void Light(bool on)
        {
            if (on) highlight.SetResourceReference(Border.BorderBrushProperty, "AccentBrush");
            else highlight.BorderBrush = System.Windows.Media.Brushes.Transparent;
        }
        void Over(object? _, DragEventArgs e)
        {
            var ok = Accepts(e);
            e.Effects = ok ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
            Light(ok);
        }
        target.DragEnter += Over;
        target.DragOver += Over;
        target.DragLeave += (_, _) => Light(false);
        target.Drop += (_, e) =>
        {
            e.Handled = true;
            Light(false);
            if (Accepts(e) && e.Data.GetData(DataFormats.FileDrop) is string[] files) module.Send(device(), files);
        };
    }
}

/// <summary>
/// Keeps the panel open while files are dragged over <paramref name="root"/> (its drag events are handled, so the shell does not see the
/// pointer there) and refuses drops that miss every device.
/// </summary>
internal sealed class DropHold
{
    readonly IShell _shell;
    readonly DispatcherTimer _release;
    IDisposable? _hold;

    public DropHold(FrameworkElement root, IShell shell, Action missed)
    {
        _shell = shell;
        _release = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromMilliseconds(250) };
        _release.Tick += (_, _) => Release();
        root.AllowDrop = true;
        root.PreviewDragEnter += (_, e) => Hold(e);
        root.PreviewDragOver += (_, e) => Hold(e);
        root.DragLeave += (_, _) => { if (_hold is not null) _release.Start(); };
        void Refuse(object? _, DragEventArgs e)
        {
            if (e.Handled) return;
            e.Effects = DragDropEffects.None;
            e.Handled = true;
        }
        root.DragEnter += Refuse;
        root.DragOver += Refuse;
        root.AddHandler(DragDrop.DropEvent, new DragEventHandler((_, e) =>
        {
            Release();
            if (e.Handled) return;
            e.Handled = true;
            missed();
        }), handledEventsToo: true);
    }

    void Hold(DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        _release.Stop();
        _hold ??= _shell.HoldOpen();
    }

    void Release()
    {
        _release.Stop();
        _hold?.Dispose();
        _hold = null;
    }
}

/// <summary>What to show instead of the devices: null while they are available.</summary>
internal static class TaildropEmpty
{
    public static (string Title, string Message, string? Action)? For(TaildropState st) => st.Availability switch
    {
        TaildropAvailability.Loading => null,
        TaildropAvailability.NotInstalled => ("Tailscale is not installed", "Taildrop sends files between your devices on Tailscale. Install Tailscale and sign in to use it.", "Get Tailscale"),
        TaildropAvailability.NotRunning => ("Tailscale is not running", "Start Tailscale to send files to your devices.", "Open Tailscale"),
        TaildropAvailability.Stopped => ("Tailscale is disconnected", "Connect Tailscale to send files to your devices.", "Open Tailscale"),
        TaildropAvailability.NeedsLogin => ("Sign in to Tailscale", "Sign in to Tailscale to send files to your devices.", "Open Tailscale"),
        _ when st.Devices.Count == 0 && st.Error.Length > 0 => ("Taildrop unavailable", st.Error, null),
        _ when st.Devices.Count == 0 => ("No devices can receive files", "Taildrop sends to your own devices on this tailnet. Sign in to Tailscale on another device, or check that Taildrop is on for your tailnet.", null),
        _ => null,
    };
}

/// <summary>The tab: every device as a drop target (click one to choose files), files waiting in the inbox, and the transfer line.</summary>
internal sealed class TaildropTab : Grid
{
    readonly TaildropModule _module;
    readonly TaildropState _st;
    readonly IShell _shell;
    readonly WrapPanel _tiles = new() { Margin = new Thickness(0, 0, 0, 8) };
    readonly ScrollViewer _scroll;
    readonly ContentControl _empty = new() { Focusable = false };
    readonly Border _waiting = new() { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 8, 8), Margin = new Thickness(0, 0, 0, 10) };
    readonly TextBlock _waitingText = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock _line = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly Grid _bar;
    readonly Action<double> _setBar;
    readonly Button _cancel, _show, _save;
    readonly FrameworkElement _footer;

    public TaildropTab(TaildropModule module, TaildropState st, IShell shell)
    {
        _module = module;
        _st = st;
        _shell = shell;
        Margin = new Thickness(19, 0, 19, 12);
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(46) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition());
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Background = System.Windows.Media.Brushes.Transparent; // the whole tab is a drag surface

        // Header
        var title = new TextBlock { Text = "Send to your devices", FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var hint = UiKit.Text("Drop files on a device, or click one to choose files.", "Muted");
        hint.VerticalAlignment = VerticalAlignment.Center;
        hint.TextWrapping = TextWrapping.NoWrap;
        hint.Margin = new Thickness(10, 1, 0, 0);
        var refresh = TaildropUi.IconButton(Glyphs.Refresh, "Refresh devices", module.Refresh);
        DockPanel.SetDock(refresh, Dock.Right);
        var header = new DockPanel { VerticalAlignment = VerticalAlignment.Center };
        header.Children.Add(refresh);
        header.Children.Add(title);
        header.Children.Add(hint);
        Children.Add(header);

        // Files waiting in the inbox
        _waiting.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        _save = TaildropUi.TextButton("Save to Downloads", module.SaveWaiting, "Move the waiting files into your Downloads folder", accent: true);
        DockPanel.SetDock(_save, Dock.Right);
        var inbox = UiKit.Glyph("", 14, "TextPrimaryBrush");
        inbox.VerticalAlignment = VerticalAlignment.Center;
        inbox.Margin = new Thickness(0, 0, 8, 0);
        var waitingRow = new DockPanel();
        waitingRow.Children.Add(_save);
        waitingRow.Children.Add(inbox);
        waitingRow.Children.Add(_waitingText);
        _waiting.Child = waitingRow;
        SetRow(_waiting, 1);
        Children.Add(_waiting);

        // Devices, or why there are none
        _scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Content = _tiles };
        SetRow(_scroll, 2);
        SetRow(_empty, 2);
        Children.Add(_scroll);
        Children.Add(_empty);

        // Transfer line
        (_bar, _setBar) = TaildropUi.Bar();
        _bar.Margin = new Thickness(0, 0, 0, 6);
        _cancel = TaildropUi.TextButton("Cancel", module.Cancel, "Stop sending");
        _show = TaildropUi.TextButton("Show", module.ShowSaved, "Show the saved file in File Explorer");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(_show);
        buttons.Children.Add(_cancel);
        DockPanel.SetDock(buttons, Dock.Right);
        var lineRow = new DockPanel { MinHeight = 26 };
        lineRow.Children.Add(buttons);
        lineRow.Children.Add(_line);
        var footer = new StackPanel();
        footer.Children.Add(_bar);
        footer.Children.Add(lineRow);
        _footer = footer;
        SetRow(footer, 3);
        Children.Add(footer);

        _ = new DropHold(this, shell, () => _st.SetTransfer(false, null, "Drop the files on a device to send them.", "TextSecondaryBrush", -1));
        st.Changed += Render;
        st.TransferChanged += RenderTransfer;
        Render();
        RenderTransfer();
    }

    void Render()
    {
        var empty = TaildropEmpty.For(_st);
        _empty.Content = empty is { } e ? EmptyView(e.Title, e.Message, e.Action) : null;
        _empty.Visibility = empty is null ? Visibility.Collapsed : Visibility.Visible;
        _scroll.Visibility = empty is null ? Visibility.Visible : Visibility.Collapsed;

        var waiting = _st.Availability == TaildropAvailability.Ready ? _st.Waiting : [];
        _waiting.Visibility = waiting.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        _waitingText.Text = waiting.Count switch
        {
            0 => "",
            1 => $"{waiting[0].Name} is waiting in Taildrop",
            _ => $"{waiting.Count} files are waiting in Taildrop",
        };
        _waitingText.ToolTip = string.Join("\n", waiting.Select(w => w.Name));

        _tiles.Children.Clear();
        if (empty is not null) return;
        if (_st.Error.Length > 0)
        {
            var err = UiKit.Text(_st.Error, "Muted");
            err.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush");
            err.Width = 660;
            err.Margin = new Thickness(0, 0, 0, 8);
            _tiles.Children.Add(err);
        }
        foreach (var d in _st.Devices) _tiles.Children.Add(Tile(d));
    }

    void RenderTransfer()
    {
        _line.Text = _st.Line;
        _line.SetResourceReference(TextBlock.ForegroundProperty, _st.LineBrush);
        _bar.Visibility = _st.Progress >= 0 ? Visibility.Visible : Visibility.Collapsed;
        _setBar(Math.Max(0, _st.Progress));
        _cancel.Visibility = _st.Busy && _st.BusyDevice is not null ? Visibility.Visible : Visibility.Collapsed;
        _show.Visibility = !_st.Busy && _st.Saved is not null && _st.LineBrush == "SuccessBrush" ? Visibility.Visible : Visibility.Collapsed;
        _footer.Visibility = _st.Line.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _save.IsEnabled = !_st.Busy;
        foreach (var tile in _tiles.Children.OfType<FrameworkElement>()) if (tile.Tag is Action refresh) refresh();
    }

    FrameworkElement Tile(TaildropDevice d)
    {
        var glyph = UiKit.Glyph(TaildropUi.DeviceGlyph(d), 20, d.Online ? "TextPrimaryBrush" : "TextTertiaryBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Left;
        var name = new TextBlock { Text = d.Name, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 8, 0, 0) };
        name.SetResourceReference(TextBlock.ForegroundProperty, d.Online ? "TextPrimaryBrush" : "TextSecondaryBrush");
        var sub = new TextBlock { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 2, 0, 0) };
        var content = new StackPanel { Width = 133 }; // four tiles fill the 674 DIP row: 4 x (160 + 8)
        content.Children.Add(glyph);
        content.Children.Add(name);
        content.Children.Add(sub);

        var button = new Button { Content = content, Padding = new Thickness(12, 10, 12, 10), IsEnabled = d.Online, ToolTip = d.Online ? $"Send files to {d.Name}" : $"{d.Name} is offline" };
        AutomationProperties.SetName(button, $"{d.Name}, {(d.Online ? "online" : "offline")}");
        button.Click += (_, _) => TaildropUi.Pick(_module, _shell, d);
        var frame = new Border { Child = button, Width = 160, CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(1.5), Margin = new Thickness(0, 0, 8, 8), BorderBrush = System.Windows.Media.Brushes.Transparent };
        // Offline tiles still take the drag, so the drop is refused instead of falling through to the file tray.
        TaildropUi.DropOn(frame, frame, _module, _st, () => d);

        void Refresh()
        {
            var sending = _st.Busy && _st.BusyDevice == d.Id;
            var os = TaildropUi.OsName(d.Os);
            sub.Text = sending ? (_st.Progress >= 0 ? $"Sending · {_st.Progress:P0}" : "Sending") : d.Online ? (os.Length > 0 ? $"{os} · Online" : "Online") : "Offline";
            sub.SetResourceReference(TextBlock.ForegroundProperty, sending ? "AccentBrush" : d.Online ? "TextSecondaryBrush" : "TextTertiaryBrush");
            button.IsEnabled = d.Online && !_st.Busy;
        }
        frame.Tag = (Action)Refresh;
        Refresh();
        return frame;
    }

    FrameworkElement EmptyView(string title, string message, string? action)
    {
        var p = (StackPanel)Placeholder.Create(TaildropModule.Icon, title, message);
        p.Margin = new Thickness(0, 0, 0, 30);
        if (action is not null)
        {
            var b = TaildropUi.TextButton(action, _module.OpenTailscale);
            b.HorizontalAlignment = HorizontalAlignment.Center;
            b.Margin = new Thickness(0, 12, 0, 0);
            p.Children.Add(b);
        }
        return p;
    }
}

/// <summary>Home card body: online devices as drop targets (a click chooses files) and the transfer line. Other states open the tab.</summary>
internal sealed class TaildropCard : Grid
{
    readonly TaildropModule _module;
    readonly TaildropState _st;
    readonly IShell _shell;
    readonly StackPanel _rows = new() { VerticalAlignment = VerticalAlignment.Top };
    readonly ContentControl _empty = new() { Focusable = false };
    readonly TextBlock _line = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Bottom };
    readonly Grid _bar;
    readonly Action<double> _setBar;

    public TaildropCard(TaildropModule module, TaildropState st, IShell shell)
    {
        _module = module;
        _st = st;
        _shell = shell;
        Background = System.Windows.Media.Brushes.Transparent;
        RowDefinitions.Add(new RowDefinition());
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Children.Add(_rows);
        Children.Add(_empty);
        (_bar, _setBar) = TaildropUi.Bar();
        _bar.Margin = new Thickness(0, 4, 0, 0);
        var foot = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom };
        foot.Children.Add(_line);
        foot.Children.Add(_bar);
        SetRow(foot, 1);
        Children.Add(foot);
        _ = new DropHold(this, shell, () => { });
        st.Changed += Render;
        st.TransferChanged += Render;
        Render();
    }

    void Render()
    {
        var empty = TaildropEmpty.For(_st);
        var online = _st.Devices.Where(d => d.Online).ToList();
        if (empty is null && online.Count == 0) empty = ("", "No devices are online.", null);
        _empty.Content = empty is { } e ? Compact(e.Title.Length > 0 ? e.Title : e.Message) : null;
        _empty.Visibility = empty is null ? Visibility.Collapsed : Visibility.Visible;

        var line = _st.Line.Length > 0 ? _st.Line
            : _st.Availability == TaildropAvailability.Ready && _st.Waiting.Count > 0 ? $"{TaildropModule.Count(_st.Waiting.Count)} waiting in Taildrop" : "";
        _line.Text = _st.Busy && _st.Progress >= 0 ? $"{_st.Progress:P0} · {_st.Line}" : line;
        _line.SetResourceReference(TextBlock.ForegroundProperty, _st.Line.Length > 0 ? _st.LineBrush : "AccentBrush");
        _line.ToolTip = _line.Text.Length > 0 ? _line.Text : null;
        _line.Visibility = _line.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _bar.Visibility = _st.Progress >= 0 ? Visibility.Visible : Visibility.Collapsed;
        _setBar(Math.Max(0, _st.Progress));

        _rows.Children.Clear();
        if (empty is not null) return;
        foreach (var d in online.Take(_line.Visibility == Visibility.Visible ? 2 : 3)) _rows.Children.Add(Row(d));
    }

    FrameworkElement Row(TaildropDevice d)
    {
        var glyph = UiKit.Glyph(TaildropUi.DeviceGlyph(d), 13, "TextSecondaryBrush");
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var dot = new System.Windows.Shapes.Ellipse { Width = 6, Height = 6, VerticalAlignment = VerticalAlignment.Center };
        dot.SetResourceReference(System.Windows.Shapes.Shape.FillProperty, _st.Busy && _st.BusyDevice == d.Id ? "AccentBrush" : "SuccessBrush");
        DockPanel.SetDock(glyph, Dock.Left);
        DockPanel.SetDock(dot, Dock.Right);
        var name = new TextBlock { Text = d.Name, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(8, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        var line = new DockPanel();
        line.Children.Add(glyph);
        line.Children.Add(dot);
        line.Children.Add(name);
        var b = new Button { Content = line, Padding = new Thickness(6, 4, 6, 4), IsEnabled = !_st.Busy, ToolTip = $"Send files to {d.Name} (or drop them here)",
            Style = (Style)Application.Current.FindResource("LinkButton") };
        b.SetResourceReference(Control.ForegroundProperty, "TextPrimaryBrush");
        AutomationProperties.SetName(b, $"Send files to {d.Name}");
        b.Click += (_, _) => TaildropUi.Pick(_module, _shell, d);
        var frame = new Border { Child = b, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1), BorderBrush = System.Windows.Media.Brushes.Transparent,
            Background = System.Windows.Media.Brushes.Transparent, Margin = new Thickness(-6, 0, -6, 2) };
        b.MouseEnter += (_, _) => frame.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        b.MouseLeave += (_, _) => frame.Background = System.Windows.Media.Brushes.Transparent;
        TaildropUi.DropOn(frame, frame, _module, _st, () => d);
        return frame;
    }

    FrameworkElement Compact(string message)
    {
        var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Cursor = Cursors.Hand };
        var g = UiKit.Glyph(TaildropModule.Icon, 18, "TextTertiaryBrush");
        g.HorizontalAlignment = HorizontalAlignment.Center;
        var t = UiKit.Text(message, "Muted");
        t.TextAlignment = TextAlignment.Center;
        t.Margin = new Thickness(0, 6, 0, 0);
        sp.Children.Add(g);
        sp.Children.Add(t);
        sp.MouseLeftButtonUp += (_, _) => _shell.SelectTab(TaildropModule.TabId);
        return sp;
    }
}
