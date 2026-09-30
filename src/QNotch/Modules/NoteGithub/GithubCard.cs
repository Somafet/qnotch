using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using QNotch.Core;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.NoteGithub;

/// <summary>GitHub card body (spans two columns): totals, contribution grid, and explicit no-token, loading and error states.</summary>
internal sealed class GithubCard : Grid
{
    readonly NoteGithubState _s;
    readonly GithubService _svc;
    readonly FrameworkElement _ready, _noToken, _loading, _error;
    readonly ContributionGraph _graph = new();
    readonly TextBlock _total = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _streak = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _status = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _errorText = UiKit.Text("", "Muted");
    readonly Button _refresh = new() { Style = (Style)Application.Current.FindResource("IconButton"), Content = Glyphs.Refresh, Width = 24, Height = 24, ToolTip = "Refresh now" };

    public GithubCard(NoteGithubState state, GithubService service, IShell shell)
    {
        _s = state;
        _svc = service;
        _total.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimaryBrush");
        _streak.SetResourceReference(TextBlock.ForegroundProperty, "AccentBrush");
        _refresh.Click += (_, _) => _ = _svc.RefreshAsync();

        _ready = BuildReady();
        _noToken = Centered(Glyphs.Github, "Connect GitHub", "Add a personal access token to see your contribution graph.",
            Action("Add token", () => shell.OpenSettings("github")));
        _loading = Centered(Glyphs.Github, "Loading activity", "Fetching your contributions from GitHub.", null);
        _errorText.TextAlignment = TextAlignment.Left;
        _error = Centered(Glyphs.Warning, "Could not load activity", "", Action("Retry", () => _ = _svc.RefreshAsync()), _errorText);

        foreach (var e in new[] { _ready, _noToken, _loading, _error }) Children.Add(e);
        _s.PropertyChanged += OnChanged;
        Sync();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName?.StartsWith("Github", StringComparison.Ordinal) == true) Sync();
    }

    void Sync()
    {
        var st = _s.GithubStatus;
        _ready.Visibility = st == GithubStatus.Ready ? Visibility.Visible : Visibility.Collapsed;
        _noToken.Visibility = st == GithubStatus.NoToken ? Visibility.Visible : Visibility.Collapsed;
        _loading.Visibility = st == GithubStatus.Loading ? Visibility.Visible : Visibility.Collapsed;
        _error.Visibility = st == GithubStatus.Error ? Visibility.Visible : Visibility.Collapsed;
        _refresh.IsEnabled = !_s.GithubRefreshing;
        _refresh.ToolTip = _s.GithubRefreshing ? "Refreshing" : "Refresh now";
        if (st == GithubStatus.Error) _errorText.Text = _s.GithubMessage;
        if (st != GithubStatus.Ready) return;

        _graph.Data = _s.GithubGraph;
        _total.Text = _s.GithubTotalText;
        _streak.Text = _s.GithubStreakText;
        var warn = _s.GithubMessage.Length > 0;
        _status.Text = warn ? $"{_s.GithubMessage} {_s.GithubUpdatedText}." : $"@{_s.GithubLogin} · {_s.GithubUpdatedText}";
        _status.ToolTip = warn ? _status.Text : null;
        _status.SetResourceReference(TextBlock.ForegroundProperty, warn ? "WarningBrush" : "TextTertiaryBrush");
    }

    FrameworkElement BuildReady()
    {
        var g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition());
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Header: totals left, refresh right. The 24 px button overhangs the row so the text stays aligned with other cards.
        var head = new DockPanel { Height = 20 };
        _refresh.Margin = new Thickness(0, -2, -4, -2);
        DockPanel.SetDock(_refresh, Dock.Right);
        head.Children.Add(_refresh);
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        var dot = UiKit.Text("·", "Muted");
        dot.Margin = new Thickness(8, 0, 8, 0);
        dot.VerticalAlignment = VerticalAlignment.Center;
        line.Children.Add(_total);
        line.Children.Add(dot);
        line.Children.Add(_streak);
        head.Children.Add(line);
        g.Children.Add(head);

        _graph.Margin = new Thickness(0, 4, 0, 4);
        Grid.SetRow(_graph, 1);
        g.Children.Add(_graph);

        var foot = new DockPanel { Height = 14 };
        var legend = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        DockPanel.SetDock(legend, Dock.Right);
        legend.Children.Add(UiKit.Text("Less", "Muted"));
        for (var i = 0; i < 5; i++)
        {
            var sw = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(2), Margin = new Thickness(i == 0 ? 5 : 2, 0, i == 4 ? 5 : 0, 0), Opacity = i == 0 ? 1 : ContributionGraph.LevelOpacity[i] };
            sw.SetResourceReference(Border.BackgroundProperty, i == 0 ? "ControlHoverBrush" : "AccentBrush");
            legend.Children.Add(sw);
        }
        legend.Children.Add(UiKit.Text("More", "Muted"));
        foot.Children.Add(legend);
        foot.Children.Add(_status);
        Grid.SetRow(foot, 2);
        g.Children.Add(foot);
        return g;
    }

    static Button Action(string text, System.Action onClick)
    {
        var b = new Button { Content = text, Style = (Style)Application.Current.FindResource("AccentButton"), Padding = new Thickness(12, 5, 12, 5), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Icon, title and message on the left, optional action button on the right.</summary>
    static FrameworkElement Centered(string glyph, string title, string message, Button? action, TextBlock? messageBlock = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var icon = UiKit.Glyph(glyph, 22, "TextTertiaryBrush");
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 12, 0);
        row.Children.Add(icon);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 230 };
        text.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.FindResource("Title"), FontSize = 13 });
        var m = messageBlock ?? UiKit.Text(message, "Muted");
        m.Margin = new Thickness(0, 2, 0, 0);
        m.MaxHeight = 42;
        m.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(m);
        row.Children.Add(text);
        if (action is not null) row.Children.Add(action);
        return row;
    }
}
