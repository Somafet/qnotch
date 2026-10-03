using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace QNotch.Modules.Notifications;

public partial class NotificationsTab : UserControl
{
    readonly NotificationsModule _module;

    internal NotificationsTab(NotificationsModule module, NotificationsState state)
    {
        _module = module;
        InitializeComponent();
        DataContext = state;
    }

    void OnAction(object sender, RoutedEventArgs e) { if ((sender as FrameworkElement)?.DataContext is NoteAction a) _module.Invoke(a); }
    void OnDismiss(object sender, RoutedEventArgs e) { if ((sender as FrameworkElement)?.DataContext is Note n) _module.Dismiss(n); }
    void OnClear(object sender, RoutedEventArgs e) => _module.Clear();
    void OnSeen(object sender, MouseEventArgs e) => _module.Seen();
}
