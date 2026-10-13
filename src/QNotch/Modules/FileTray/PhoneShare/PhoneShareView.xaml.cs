using System.Windows;
using System.Windows.Controls;
using QNotch.Core;

namespace QNotch.Modules.FileTray;

public partial class PhoneShareView : UserControl
{
    readonly PhoneShareService _svc;
    readonly PhoneShareState _state;

    public PhoneShareView(PhoneShareService svc, PhoneShareState state)
    {
        _svc = svc;
        _state = state;
        DataContext = state;
        InitializeComponent();
    }

    void OnAll(object sender, RoutedEventArgs e) => _svc.SelectAll(true);
    void OnNone(object sender, RoutedEventArgs e) => _svc.SelectAll(false);
    void OnStart(object sender, RoutedEventArgs e) => _svc.Start();
    void OnExtend(object sender, RoutedEventArgs e) => _svc.Extend();

    void OnReveal(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is PhoneTransfer t) _svc.Reveal(t);
    }

    void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_state.Url.Length == 0) return;
        try { System.Windows.Clipboard.SetText(_state.Url); }
        catch (Exception ex) { Log.Warn("Phone sharing: copy link failed", ex); }
    }
}
