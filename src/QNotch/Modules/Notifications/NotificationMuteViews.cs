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
        ToggleButton button = compact
            ? new ToggleButton { Style = (Style)Application.Current.FindResource("IconToggle"), Margin = new Thickness(0, 0, 4, 0) }
            : UiKit.Toggle();
        System.Windows.Automation.AutomationProperties.SetAutomationId(button, compact ? "panel-notifications-mute" : "notifications-mute");
        button.Checked += (_, _) => module.SetMuted(true);
        button.Unchecked += (_, _) => module.SetMuted(false);
        void Sync()
        {
            button.IsChecked = state.Muted;
            if (compact) button.Content = state.Muted ? MutedGlyph : NotifyIcons.Bell;
            button.ToolTip = state.Muted ? "Notifications muted. Click to unmute." : "Mute notifications";
            System.Windows.Automation.AutomationProperties.SetName(button, compact && state.Muted ? "Unmute notifications (muted)" : "Mute notifications");
        }
        System.ComponentModel.PropertyChangedEventManager.AddHandler(state, (_, _) => Sync(), nameof(NotificationsState.Muted));
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
