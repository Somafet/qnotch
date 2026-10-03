using System.ComponentModel;
using System.Windows;
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
    public static string Meta(AgentSession s) => s.Status switch
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
    static FrameworkElement? UsageColumn(AgentsState st, AgentSession s)
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

    public static UIElement Row(AgentsModule module, AgentsState st, AgentSession s)
    {
        var icon = UiKit.Glyph(s.Status == AgentStatus.Done ? Glyphs.Accept : AgentsModule.Icon, 14, StatusBrush(s.Status));
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        var tile = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), Child = icon };
        tile.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");

        var name = new TextBlock { Text = s.Name, FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = s.Cwd.Length > 0 ? s.Cwd : null };
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
        if (s.Window != 0) buttons.Children.Add(IconButton(ShowGlyph, "Show its terminal", () => module.Show(s)));
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
        return Hover(g);
    }
}

/// <summary>The tab: every session, the ones that need you first.</summary>
internal sealed class AgentsTab : Grid
{
    readonly AgentsModule _module;
    readonly AgentsState _st;
    readonly StackPanel _rows = new() { Margin = new Thickness(0, 0, 0, 12) };
    readonly FrameworkElement _empty;

    public AgentsTab(AgentsModule module, AgentsState st)
    {
        _module = module;
        _st = st;
        Margin = new Thickness(19, 2, 19, 0);
        _empty = Placeholder.Create(AgentsModule.Icon, "No agents running",
            "Claude Code sessions show up here with what they are doing. Connect Claude Code in Settings, Agents, then start a session.");
        if (_empty is Panel p)
        {
            var open = new Button { Content = "Open settings", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0), Padding = new Thickness(12, 4, 12, 4) };
            open.Click += (_, _) => module.OpenSettings();
            p.Children.Add(open);
        }
        Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false, Content = _rows });
        Children.Add(_empty);
        st.Changed += Render;
        Render();
    }

    void Render()
    {
        _empty.Visibility = _st.Sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _rows.Children.Clear();
        if (_st.Sessions.Count > 0 && AgentsViews.TodayLine(_st) is { } today) _rows.Children.Add(today);
        foreach (var s in _st.Sessions) _rows.Children.Add(AgentsViews.Row(_module, _st, s));
    }
}

/// <summary>Settings, Agents: connect or disconnect each Claude Code config folder.</summary>
internal static class AgentsSettings
{
    public static FrameworkElement Create(bool readOnly)
    {
        var page = UiKit.Page("Agents");
        var intro = UiKit.Text("Claude Code tells QNotch what each session is doing through hooks in its settings.json. Everything stays on this PC.", "Muted");
        intro.Margin = new Thickness(0, -8, 0, 16);
        page.Children.Add(intro);

        foreach (var hooks in ClaudeHooks.Discover())
        {
            var button = new Button { MinWidth = 96, IsEnabled = !readOnly };
            var row = UiKit.Row(hooks.Account == "Default" ? "Claude Code" : $"Claude Code ({hooks.Account})", "", button);
            var hint = (TextBlock)((StackPanel)row.Children[0]).Children[1];
            page.Children.Add(row);
            var connected = false;

            void Sync()
            {
                var (status, detail) = hooks.Check();
                connected = status == HookStatus.Connected;
                button.Content = connected ? "Disconnect" : status == HookStatus.OtherCopy ? "Use this copy" : "Connect";
                button.Style = connected ? null : (Style)Application.Current.FindResource("AccentButton");
                hint.Text = status switch
                {
                    HookStatus.Connected => "Connected. Sessions that were already open show up after you restart them.",
                    HookStatus.OtherCopy => $"Connected to another copy of QNotch ({detail}).",
                    HookStatus.Error => $"Could not read settings.json: {detail}",
                    _ => $"Adds hooks to {System.IO.Path.Combine(hooks.Dir, "settings.json")} and keeps a backup next to it.",
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
                catch (Exception ex) { error = ex.Message; Core.Log.Warn("Changing Claude Code hooks failed", ex); }
                Sync();
                if (error is not null) { hint.Text = $"Could not change settings.json: {error}"; hint.SetResourceReference(TextBlock.ForegroundProperty, "DangerBrush"); }
                button.IsEnabled = true;
            };
            Sync();
        }
        return page;
    }
}
