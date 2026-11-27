using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using QNotch.Core;
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
            button.ToolTip = state.Muted ? L.T("Notifications muted. Click to unmute.") : L.T("Mute notifications");
            System.Windows.Automation.AutomationProperties.SetName(button, compact && state.Muted ? L.T("Unmute notifications (muted)") : L.T("Mute notifications"));
        }
        System.ComponentModel.PropertyChangedEventManager.AddHandler(state, (_, _) => Sync(), nameof(NotificationsState.Muted));
        Sync();
        return button;
    }

    public static MenuItem Tray(NotificationsModule module, NotificationsState state)
    {
        var item = new MenuItem { Header = L.T("Mute notifications"), IsCheckable = true, IsChecked = state.Muted };
        item.Click += (_, _) => module.SetMuted(!state.Muted);
        return item;
    }
}
