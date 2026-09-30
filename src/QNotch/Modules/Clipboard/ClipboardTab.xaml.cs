using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Core;

namespace QNotch.Modules.Clipboard;

public partial class ClipboardTab : UserControl
{
    readonly ClipboardModule _module;
    readonly ClipboardState _state;

    internal ClipboardTab(ClipboardModule module, ClipboardState state)
    {
        _module = module;
        _state = state;
        InitializeComponent();
        DataContext = state;
    }

    static ClipEntry? Entry(object sender) => (sender as FrameworkElement)?.DataContext as ClipEntry;

    void OnFilter(object sender, RoutedEventArgs e)
    {
        if (sender is RadioButton { Tag: string tag } && Enum.TryParse<ClipFilter>(tag, out var f)) _state.Filter = f;
    }

    void OnRowClick(object sender, MouseButtonEventArgs e) { if (Entry(sender) is { } en) _module.CopyAgain(en); }
    void OnCopy(object sender, RoutedEventArgs e) { if (Entry(sender) is { } en) _module.CopyAgain(en); }
    void OnPin(object sender, RoutedEventArgs e) { if (Entry(sender) is { } en) _module.TogglePin(en); }
    void OnRemove(object sender, RoutedEventArgs e) { if (Entry(sender) is { } en) _module.Remove(en); }
    void OnClear(object sender, RoutedEventArgs e) => _module.Clear();
}
