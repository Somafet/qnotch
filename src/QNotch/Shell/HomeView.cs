using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell;

/// <summary>Home tab: responsive card grid rendered from CardLayout. Card bodies are created once and reused.</summary>
public sealed class HomeView : ScrollViewer
{
    public const double Unit = 218, Gap = 10, RowHeight = 148;

    readonly CardLayout _layout;
    readonly IShell _shell;
    readonly WrapPanel _panel = new() { Width = 3 * (Unit + Gap) };
    readonly Dictionary<string, CardHost> _hosts = new();

    public HomeView(CardLayout layout, IShell shell)
    {
        _layout = layout;
        _shell = shell;
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Padding = new Thickness(12, 0, 4, 12);
        Content = _panel;
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
                host = new CardHost(d)
                {
                    Content = Create(d),
                    Width = d.ColumnSpan * Unit + (d.ColumnSpan - 1) * Gap,
                    Height = d.RowSpan * RowHeight + (d.RowSpan - 1) * Gap,
                    Margin = new Thickness(0, 0, Gap, Gap),
                    IsEditMode = _shell.IsEditMode,
                };
                _hosts[d.Id] = host;
            }
            host.OrderNumber = _layout.OrderNumber(d.Id);
            shown.Add(host);
        }
        _panel.Children.Clear();
        foreach (var h in shown) _panel.Children.Add(h);
        _layout.SetHosts(shown);
    }

    static FrameworkElement Create(CardDescriptor d)
    {
        try { return d.Factory(); }
        catch (Exception ex)
        {
            Log.Error($"Card '{d.Id}' failed to build", ex);
            return Placeholder.Create(Glyphs.Warning, "", "This card failed to load. See logs.");
        }
    }
}
