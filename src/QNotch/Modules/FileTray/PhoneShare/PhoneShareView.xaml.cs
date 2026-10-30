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

    void OnAll(object sender, RoutedEventArgs e) { QNotch.Core.Analytics.Track("files", "select_all", "ui");  _svc.SelectAll(true); }
    void OnNone(object sender, RoutedEventArgs e) { QNotch.Core.Analytics.Track("files", "select_none", "ui");  _svc.SelectAll(false); }
    void OnStart(object sender, RoutedEventArgs e) { QNotch.Core.Analytics.Track("files", "share_start", "ui");  _svc.Start(); }
    void OnExtend(object sender, RoutedEventArgs e) { QNotch.Core.Analytics.Track("files", "share_extend", "ui");  _svc.Extend(); }

    void OnReveal(object sender, RoutedEventArgs e)
    { QNotch.Core.Analytics.Track("files", "reveal_received", "ui");
        if ((sender as FrameworkElement)?.DataContext is PhoneTransfer t) _svc.Reveal(t);
    }

    void OnCopy(object sender, RoutedEventArgs e)
    { QNotch.Core.Analytics.Track("files", "share_copy_link", "ui");
        if (_state.Url.Length == 0) return;
        try { System.Windows.Clipboard.SetText(_state.Url); }
        catch (Exception ex) { Log.Warn("Phone sharing: copy link failed", ex); }
    }
}
