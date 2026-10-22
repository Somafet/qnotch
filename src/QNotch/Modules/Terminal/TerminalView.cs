using System.Windows;
using System.Windows.Controls;
using QNotch.Theme;

namespace QNotch.Modules.Terminal;

internal sealed class TerminalView : Grid, IPanelKeyboardInput
{
    readonly TextBlock _status;
    internal TerminalSurface Input { get; }
    internal TerminalView(TerminalModule module, TerminalBuffer buffer)
    {
        Margin = new Thickness(19, 2, 19, 10);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition());
        _status = UiKit.Text(module.Demo ? "Demo session · no commands run" : "Session stays open when the panel closes", "Muted");
        _status.TextTrimming = TextTrimming.CharacterEllipsis;
        _status.VerticalAlignment = VerticalAlignment.Center;
        var restart = new Button { Content = "New session", Padding = new Thickness(8, 3, 8, 3), ToolTip = "End this session and start a new shell in your home folder" };
        restart.Click += async (_, _) => await module.Restart();
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(restart, Dock.Right);
        top.Children.Add(restart); top.Children.Add(_status); Children.Add(top);
        Input = new TerminalSurface(buffer, module.Send, module.Resize, module.TakeKeyboard, SetStatus);
        Grid.SetRow(Input, 1); Children.Add(Input);
        IsVisibleChanged += (_, _) => { if (IsVisible) module.EnsureSession(); };
    }
    internal void SetStatus(string text) => _status.Text = text;
    public void FocusInput() => Input.Focus();
}
