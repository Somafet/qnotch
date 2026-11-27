using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell;

/// <summary>Home tab: responsive card grid rendered from CardLayout. Card bodies are created once and reused.</summary>
public sealed class HomeView : ScrollViewer
{
    /// <summary>Column width, gap between cards, row height (DIPs). A card spanning n columns is n * Unit + (n - 1) * Gap wide.
    /// The grid keeps <see cref="PanelMetrics.Gap"/> to the panel's sides, between cards and, with two rows, to the bottom.</summary>
    public const double Gap = PanelMetrics.Gap, Unit = (NotchWindow.PanelW - 4 * Gap) / 3, RowHeight = 149;

    readonly CardLayout _layout;
    readonly ShellController _shell;
    readonly WrapPanel _panel = new() { Width = 3 * (Unit + Gap), HorizontalAlignment = HorizontalAlignment.Center };
    readonly Dictionary<string, CardHost> _hosts = new();
    readonly StackPanel _root = new();

    public HomeView(CardLayout layout, ShellController shell)
    {
        _layout = layout;
        _shell = shell;
        Style = (Style)Application.Current.FindResource(typeof(ScrollViewer)); // implicit styles skip subclasses
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Padding = new Thickness(0); // each card's bottom margin is the gap
        Content = _root;
        layout.Changed += Rebuild;
        shell.EditModeChanged += () => { foreach (var h in _hosts.Values) h.IsEditMode = shell.IsEditMode; };
        Rebuild();
    }

    void Rebuild()
    {
        var shown = new List<CardHost>();
        foreach (var d in _layout.Visible)
        {
            if (!_hosts.TryGetValue(d.Id, out var host))
            {
                host = new CardHost(d, _layout)
                {
                    Content = Create(d),
                    Height = RowHeight,
                    Margin = new Thickness(Gap / 2, 0, Gap / 2, Gap),
                    IsEditMode = _shell.IsEditMode,
                };
                _hosts[d.Id] = host;
            }
            host.Width = (int)_layout.SizeOf(d.Id) * (Unit + Gap) - Gap;
            host.SyncSize();
            host.OrderNumber = _layout.OrderNumber(d.Id);
            shown.Add(host);
        }
        // A size change only rearranges the existing children, preserving keyboard focus on its size choice.
        if (!_panel.Children.Cast<CardHost>().SequenceEqual(shown))
        {
            _panel.Children.Clear();
            foreach (var h in shown) _panel.Children.Add(h);
        }
        if (_root.Children.Count != 1 || _root.Children[0] != _panel || shown.Count == 0)
        {
            _root.Children.Clear();
            _root.Children.Add(_panel);
        }
        if (shown.Count == 0)
        {
            _root.Children.Add(Placeholder.Create(Glyphs.Apps, L.T("Your Home is empty"), L.T("Choose what appears here in Settings, Features.")));
            var recover = new Button { Content = L.T("Open Features"), HorizontalAlignment = HorizontalAlignment.Center };
            recover.Click += (_, _) => _shell.OpenSettings("features");
            _root.Children.Add(recover);
        }
        _layout.SetHosts(shown);
    }

    static FrameworkElement Create(CardDescriptor d)
    {
        try { return d.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Card '{d.Id}' failed to build", ex);
            return Placeholder.Create(Glyphs.Warning, "", L.T("This card failed to load. See logs."));
        }
    }
}
