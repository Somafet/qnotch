using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Theme;

namespace QNotch.Modules.Terminal;

internal sealed class TerminalView : Grid, IPanelKeyboardInput
{
    readonly TextBlock _status;
    internal TerminalSurface Input { get; }
    internal TerminalView(TerminalModule module, TerminalBuffer buffer)
    {
        Margin = PanelMetrics.Page with { Top = 2 };
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition());
        _status = UiKit.Text(module.Demo ? L.T("Demo session · no commands run") : L.T("Session stays open when the panel closes"), "Muted");
        _status.TextTrimming = TextTrimming.CharacterEllipsis;
        _status.VerticalAlignment = VerticalAlignment.Center;
        var restart = new Button { Content = L.T("New session"), Padding = new Thickness(8, 3, 8, 3), ToolTip = L.T("End this session and start a new shell in your home folder") };
        restart.Click += async (_, _) => await module.Restart();
        var top = new DockPanel { Margin = PanelMetrics.Caption with { Bottom = 6 } };
        DockPanel.SetDock(restart, Dock.Right);
        top.Children.Add(restart); top.Children.Add(_status); Children.Add(top);
        Input = new TerminalSurface(buffer, module.Send, module.Resize, module.TakeKeyboard, SetStatus);
        var card = new Border { CornerRadius = PanelMetrics.Card, BorderThickness = new Thickness(1), Child = Input };
        card.SetResourceReference(Border.BackgroundProperty, "CardBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "StrokeBrush");
        Grid.SetRow(card, 1); Children.Add(card);
        IsVisibleChanged += (_, _) => { if (IsVisible) module.EnsureSession(); };
    }
    internal void SetStatus(string text) => _status.Text = text;
    public void FocusInput() => Input.Focus();
}
