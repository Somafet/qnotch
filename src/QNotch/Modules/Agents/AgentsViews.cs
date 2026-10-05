using System.ComponentModel;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using QNotch.Theme;

namespace QNotch.Modules.Agents;

internal static class AgentsViews
{
    const string ShowGlyph = "";

    public static string StatusBrush(AgentStatus s) => s switch
    {
        AgentStatus.NeedsYou => "WarningBrush",
        AgentStatus.Working => "AccentBrush",
        AgentStatus.Done => "TextSecondaryBrush",
        _ => "TextTertiaryBrush",
    };

    /// <summary>The second line of a row: what it waits for, or how long it has been in its state.</summary>
    /// <summary>
    /// "Working for 6m", after the folder when the title took the name's place ("api · Working"). Codex rows say so
    /// ("Codex · Working"); a permission prompt already names the agent.
    /// </summary>
    public static string Meta(AgentSession s) => string.Join(" · ", new[]
    {
        s.Agent == "codex" && s.Status != AgentStatus.NeedsYou ? "Codex" : "",
        s.Title.Length > 0 ? s.Name : "",
        Status(s),
    }.Where(t => t.Length > 0));

    static string Status(AgentSession s) => s.Status switch
    {
        AgentStatus.NeedsYou => s.Message,
        AgentStatus.Working => DateTime.UtcNow - s.Since < TimeSpan.FromMinutes(1) ? "Working" : $"Working for {Span(DateTime.UtcNow - s.Since)}",
        AgentStatus.Done => DateTime.UtcNow - s.Since < TimeSpan.FromMinutes(1) ? "Done just now" : $"Done {Span(DateTime.UtcNow - s.Since)} ago",
        _ => "Ready",
    };

    static string Span(TimeSpan t) => t.TotalHours >= 1 ? $"{(int)t.TotalHours}h" : $"{Math.Max(1, (int)t.TotalMinutes)}m";

    /// <summary>Pill and game bar: a status dot and "api needs you" or "2 working". Collapsed while nothing runs.</summary>
    public static FrameworkElement Segment(AgentsState st)
    {
        var dot = new Ellipse { Width = 7, Height = 7, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        var text = new TextBlock { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 140, TextTrimming = TextTrimming.CharacterEllipsis };
        UiKit.Bind(text, TextBlock.TextProperty, st, nameof(AgentsState.PillText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        p.Children.Add(dot);
        p.Children.Add(text);

        void Sync()
        {
            dot.SetResourceReference(Shape.FillProperty, st.NeedsYou ? "WarningBrush" : "AccentBrush");
            text.SetResourceReference(TextBlock.ForegroundProperty, st.NeedsYou ? "WarningBrush" : "TextPrimaryBrush");
        }
        st.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AgentsState.NeedsYou)) Sync(); };
        Sync();
        return UiKit.BindVisible(p, st, nameof(AgentsState.PillVisible));
    }

    /// <summary>A rounded row that lights up under the pointer.</summary>
    public static Border Hover(UIElement child)
    {
        var b = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 8, 10, 8), Margin = new Thickness(0, 0, 0, 4), Child = child };
        b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        b.MouseEnter += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlHoverBrush");
        b.MouseLeave += (_, _) => b.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        return b;
    }

    public static Button IconButton(string glyph, string tip, Action click)
    {
        var b = new Button { Content = glyph, ToolTip = tip, Width = 26, Height = 26, Margin = new Thickness(4, 0, 0, 0), Style = (Style)Application.Current.FindResource("IconButton") };
        b.Click += (_, _) => click();
        return b;
    }

    const string PriceNote = "At API list prices. A Pro or Max plan is not billed per token.";

    /// <summary>Right side of a row: what the session used today. Null before any usage is known.</summary>
    static FrameworkElement? UsageColumn(AgentsState st, AgentSession s, UIElement? below = null)
    {
        if (!st.Usage.TryGetValue(s.Id, out var u) || u.Today.Tokens == 0) return null;
        var cost = new TextBlock { Text = Usage.FormatCost(u.Today), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right };
        var tokens = UiKit.Text($"{Usage.FormatTokens(u.Today.Tokens)} tokens", "Muted");
        tokens.HorizontalAlignment = HorizontalAlignment.Right;
        tokens.Margin = new Thickness(0, 2, 0, 0);
        var tip = $"Today: {u.Today}";
        if (u.Total.Tokens != u.Today.Tokens) tip += $"\nWhole session: {u.Total}";
        if (st.ProjectToday(s.Cwd) is var p && p.Tokens != u.Today.Tokens) tip += $"\nToday in {s.Name}: {p}";
        var col = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0), Background = Brushes.Transparent, ToolTip = $"{tip}\n{PriceNote}" };
        col.Children.Add(cost);
        col.Children.Add(tokens);
        return col;
    }

    /// <summary>Top of the tab: today across every session. Null before any usage is known.</summary>
    public static FrameworkElement? TodayLine(AgentsState st)
    {
        var today = st.Today;
        if (today.Tokens == 0) return null;
        var label = UiKit.Text("Today", "Muted");
        var value = UiKit.Text(today.ToString(), "Muted");
        value.HorizontalAlignment = HorizontalAlignment.Right;
        var g = new Grid { Margin = new Thickness(10, 0, 10, 6), Background = Brushes.Transparent, ToolTip = $"Every Claude Code session today.\n{PriceNote}" };
        g.Children.Add(label);
        g.Children.Add(value);
        return g;
    }

    public static UIElement Row(AgentsModule module, AgentsState st, AgentSession s, UIElement? below = null)
    {
        var icon = UiKit.Glyph(s.Status == AgentStatus.Done ? Glyphs.Accept : AgentsModule.Icon, 14, StatusBrush(s.Status));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var tile = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Child = icon };
        tile.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");

        var name = new TextBlock { Text = s.Title.Length > 0 ? s.Title : s.Name, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = s.Cwd.Length > 0 ? s.Cwd : null };
        var meta = UiKit.Text(Meta(s), "Muted");
        meta.TextWrapping = TextWrapping.NoWrap;
        meta.TextTrimming = TextTrimming.CharacterEllipsis;
        meta.Margin = new Thickness(0, 2, 0, 0);
        if (s.Status == AgentStatus.NeedsYou) meta.SetResourceReference(TextBlock.ForegroundProperty, "WarningBrush");
        var text = new StackPanel { Margin = new Thickness(10, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(name);
        text.Children.Add(meta);

        // Room for both buttons on every row, so the usage column lines up.
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0), MinWidth = 60 };
        if (s.Window != 0 || s.Link.Length > 0) buttons.Children.Add(IconButton(ShowGlyph, s.Link.Length > 0 ? "Open the session" : "Show its terminal", () => module.Show(s)));
        if (s.Status is AgentStatus.Done or AgentStatus.Ready) buttons.Children.Add(IconButton(Glyphs.Close, "Clear", () => module.Dismiss(s)));

        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(text, 1);
        Grid.SetColumn(buttons, 3);
        g.Children.Add(tile);
        g.Children.Add(text);
        g.Children.Add(buttons);
        if (UsageColumn(st, s) is { } usage)
        {
            Grid.SetColumn(usage, 2);
            g.Children.Add(usage);
        }
        if (below is null) return Hover(g);
        var all = new StackPanel();
        all.Children.Add(g);
        all.Children.Add(below);
        return Hover(all);
    }
}

/// <summary>The tab: every session, the ones that need you first, then what agents left running.</summary>
internal sealed class AgentsTab : Grid
{
    const string Expand = "", Collapse = "";

    readonly AgentsModule _module;
    readonly AgentsState _st;
    readonly StackPanel _rows = new() { Margin = new Thickness(0, 0, 0, 12) };
    readonly FrameworkElement _empty;
    // Process numbers change on every walk: update these texts in place while the layout stays the same, so hover and clicks survive.
    readonly Dictionary<int, TextBlock> _metas = [];
    readonly Dictionary<string, TextBlock> _summaries = [];
    string _shape = "";
    /// <summary>The group whose Stop is asking for confirmation.</summary>
    int _confirm;

    public AgentsTab(AgentsModule module, AgentsState st)
    {
        _module = module;
        _st = st;
        Margin = new Thickness(19, 2, 19, 0);
        _empty = Placeholder.Create(AgentsModule.Icon, "No agents running",
            "Claude Code and Codex sessions show up here with what they are doing. Connect them in Settings, Agents, then start a session.");
        if (_empty is Panel p)
        {
            var open = new Button { Content = "Open settings", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            open.Click += (_, _) => module.OpenSettings();
            p.Children.Add(open);
        }
        Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Content = _rows });
        Children.Add(_empty);
        st.Changed += Render;
        st.GroupsChanged += () =>
        {
            if (Shape() != _shape) { Render(); return; }
            foreach (var g in _st.Groups) if (_metas.TryGetValue(g.Root, out var t)) t.Text = Meta(g);
            foreach (var (id, t) in _summaries) t.Text = Summary(Groups(id));
        };
        Render();
    }

    string Shape() => string.Join(",", _st.Groups.Select(g => $"{g.Session}:{g.Root}:{g.LeftRunning}"));

    IEnumerable<ProcGroup> Groups(string session) => _st.Groups.Where(g => g.Session == session && !g.LeftRunning);

    void Render()
    {
        _shape = Shape();
        if (!_st.Groups.Exists(g => g.Root == _confirm)) _confirm = 0; // gone: never arm a stranger that gets its pid
        _metas.Clear();
        _summaries.Clear();
        var left = _st.Groups.Where(g => g.LeftRunning).ToList();
        _empty.Visibility = _st.Sessions.Count == 0 && left.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _rows.Children.Clear();
        if (_st.Sessions.Count > 0 && AgentsViews.TodayLine(_st) is { } today) _rows.Children.Add(today);
        foreach (var s in _st.Sessions) _rows.Children.Add(AgentsViews.Row(_module, _st, s, Processes(s)));
        if (left.Count == 0) return;
        var header = new TextBlock { Text = "Left running", FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 8, 0, 0) };
        _rows.Children.Add(header);
        var hint = UiKit.Text("Started by agents whose shell or session has ended. Nothing will stop these for you.", "Muted");
        hint.Margin = new Thickness(2, 2, 0, 8);
        _rows.Children.Add(hint);
        foreach (var g in left) _rows.Children.Add(AgentsViews.Hover(GroupRow(g)));
    }

    /// <summary>"3 processes · 412 MB · :3000" under a session, and the list while it is open.</summary>
    UIElement? Processes(AgentSession s)
    {
        var groups = Groups(s.Id).ToList();
        if (groups.Count == 0) return null;
        var chevron = UiKit.Glyph(s.Expanded ? Collapse : Expand, 10, "TextSecondaryBrush");
        chevron.VerticalAlignment = VerticalAlignment.Center;
        chevron.Margin = new Thickness(0, 0, 6, 0);
        var text = UiKit.Text(Summary(groups), "Muted");
        text.TextWrapping = TextWrapping.NoWrap;
        _summaries[s.Id] = text;
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(chevron);
        line.Children.Add(text);
        var toggle = new Button
        {
            Content = line, Padding = new Thickness(8, 3, 10, 3), HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = s.Expanded ? "Hide processes" : "Show processes",
        };
        AutomationProperties.SetName(toggle, toggle.ToolTip as string);
        toggle.Click += (_, _) => { s.Expanded = !s.Expanded; Render(); };

        var panel = new StackPanel { Margin = new Thickness(32, 4, 0, 0) };
        panel.Children.Add(toggle);
        if (s.Expanded)
            foreach (var g in groups)
            {
                var row = GroupRow(g);
                row.Margin = new Thickness(6, 6, 0, 0);
                panel.Children.Add(row);
            }
        return panel;
    }

    static string Summary(IEnumerable<ProcGroup> groups)
    {
        var list = groups.ToList();
        var count = list.Sum(g => g.Members.Length);
        return string.Join(" · ", new[]
        {
            count == 1 ? "1 process" : $"{count} processes",
            ProcessTracker.Size(list.Sum(g => g.Memory)),
            ProcessTracker.PortText([.. list.SelectMany(g => g.Ports).Distinct().Order()]),
        }.Where(t => t.Length > 0));
    }

    static string Meta(ProcGroup g) => g.LeftRunning ? string.Join(" · ", new[] { g.Project, g.Meta }.Where(t => t.Length > 0)) : g.Meta;

    /// <summary>One thing an agent started: its command, what it uses, and Stop, which asks first.</summary>
    FrameworkElement GroupRow(ProcGroup g)
    {
        var label = new TextBlock { Text = g.Label, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = g.Label };
        var meta = UiKit.Text(Meta(g), "Muted");
        meta.TextWrapping = TextWrapping.NoWrap;
        meta.TextTrimming = TextTrimming.CharacterEllipsis;
        meta.Margin = new Thickness(0, 2, 0, 0);
        _metas[g.Root] = meta;
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(label);
        text.Children.Add(meta);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        if (_confirm == g.Root)
        {
            var ask = UiKit.Text(g.Members.Length == 1 ? "End this process?" : $"End {g.Members.Length} processes?", "Muted");
            ask.VerticalAlignment = VerticalAlignment.Center;
            ask.TextWrapping = TextWrapping.NoWrap;
            var stop = new Button { Content = "Stop", Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(12, 2, 12, 2), Style = (Style)Application.Current.FindResource("AccentButton") };
            stop.Click += (_, _) => { _confirm = 0; _module.Stop(g); Render(); };
            buttons.Children.Add(ask);
            buttons.Children.Add(stop);
            buttons.Children.Add(AgentsViews.IconButton(Glyphs.Close, "Cancel", () => { _confirm = 0; Render(); }));
        }
        else
        {
            var stop = new Button { Content = "Stop", Padding = new Thickness(12, 2, 12, 2), ToolTip = "End it and everything it started" };
            stop.Click += (_, _) => { _confirm = g.Root; Render(); };
            buttons.Children.Add(stop);
        }

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(buttons, 1);
        grid.Children.Add(text);
        grid.Children.Add(buttons);
        return grid;
    }
}

/// <summary>Settings, Agents: connect or disconnect each Claude Code config folder and Codex, and the alert sounds.</summary>
internal static class AgentsSettings
{
    public static FrameworkElement Create(AgentsModule m, AgentsConfig cfg, bool readOnly)
    {
        var page = UiKit.Page("Agents");
        var intro = UiKit.Text("Claude Code and Codex tell QNotch what each session is doing through hooks in their settings. Everything stays on this PC.", "Muted");
        intro.Margin = new Thickness(0, -8, 0, 16);
        page.Children.Add(intro);

        // A snapshot shows the Codex row whether or not Codex is installed.
        foreach (var hooks in ClaudeHooks.Discover().Append<HookFile?>(CodexHooks.Find(always: readOnly)).OfType<HookFile>())
        {
            var button = new Button { MinWidth = 96, IsEnabled = !readOnly };
            var row = UiKit.Row(hooks.Title, "", button);
            var hint = (TextBlock)((StackPanel)row.Children[0]).Children[1];
            page.Children.Add(row);
            var connected = false;

            void Sync()
            {
                var (status, detail) = hooks.Check();
                connected = status == HookStatus.Connected;
                button.Content = connected ? "Disconnect" : status == HookStatus.OtherCopy ? "Use this copy" : "Connect";
                if (connected) button.ClearValue(FrameworkElement.StyleProperty); // back to the themed implicit style
                else button.Style = (Style)Application.Current.FindResource("AccentButton");
                hint.Text = status switch
                {
                    HookStatus.Connected => hooks.ConnectedHint,
                    HookStatus.OtherCopy => $"Connected to another copy of QNotch ({detail}).",
                    HookStatus.Error => $"Could not read {hooks.FileName}: {detail}",
                    _ => $"Adds hooks to {hooks.FilePath} and keeps a backup next to it.",
                };
                hint.SetResourceReference(TextBlock.ForegroundProperty, status switch
                {
                    HookStatus.Connected => "SuccessBrush",
                    HookStatus.Error => "DangerBrush",
                    HookStatus.OtherCopy => "WarningBrush",
                    _ => "TextSecondaryBrush",
                });
            }

            button.Click += async (_, _) =>
            {
                button.IsEnabled = false;
                string? error = null;
                try { await Task.Run(connected ? hooks.Disconnect : hooks.Connect); }
                catch (Exception ex) { error = ex.Message; Core.Log.Warn($"Changing {hooks.Title} hooks failed", ex); }
                Sync();
                if (error is not null) { hint.Text = $"Could not change {hooks.FileName}: {error}"; hint.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush"); }
                button.IsEnabled = true;
            };
            Sync();
        }

        page.Children.Add(UiKit.Row("Sound when an agent needs you", "Never in Game mode or while an app uses the microphone. Choose the sound in Settings, Sounds.",
            UiKit.Toggle(cfg.SoundNeedsYou, on => { cfg.SoundNeedsYou = on; m.SaveSettings(); })));
        page.Children.Add(UiKit.Row("Sound when an agent finishes", "Never in Game mode or while an app uses the microphone. Choose the sound in Settings, Sounds.",
            UiKit.Toggle(cfg.SoundDone, on => { cfg.SoundDone = on; m.SaveSettings(); })));
        return page;
    }
}
