using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using QNotch.Theme;

namespace QNotch.Modules.Notifications;

internal static class NotificationMuteViews
{
    internal const string MutedGlyph = "";

    public static FrameworkElement Button(NotificationsModule module, NotificationsState state, bool compact = false)
    {
        var button = new ToggleButton { Margin = new Thickness(0, 0, 4, 0) };
        if (compact) button.Style = (Style)Application.Current.FindResource("IconToggle");
        System.Windows.Automation.AutomationProperties.SetAutomationId(button, compact ? "panel-notifications-mute" : "notifications-mute");
        button.Checked += (_, _) => module.SetMuted(true);
        button.Unchecked += (_, _) => module.SetMuted(false);
        void Sync()
        {
            button.IsChecked = state.Muted;
            button.Content = compact ? (state.Muted ? MutedGlyph : NotifyIcons.Bell) : state.Muted ? "Unmute notifications" : "Mute notifications";
            button.ToolTip = state.Muted ? "Notifications muted. Click to unmute." : "Mute notifications";
            System.Windows.Automation.AutomationProperties.SetName(button, state.Muted ? "Unmute notifications (muted)" : "Mute notifications");
        }
        state.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(NotificationsState.Muted)) Sync(); };
        Sync();
        return button;
    }

    public static MenuItem Tray(NotificationsModule module, NotificationsState state)
    {
        var item = new MenuItem { Header = "Mute notifications", IsCheckable = true, IsChecked = state.Muted };
        item.Click += (_, _) => module.SetMuted(!state.Muted);
        return item;
    }
}
