using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Core.Updates;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

internal static class AboutSection
{
    public static FrameworkElement Create(GeneralSettings settings, UpdateService updates, Action showTour, Action quit)
    {
        var page = UiKit.Page(L.T("About"));
        var identity = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 22) };
        identity.Children.Add(new Image { Source = AppIcon.Render(120), Width = 60, Height = 60, Margin = new Thickness(0, 0, 14, 0) });
        var title = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(new TextBlock { Text = "QNotch", FontSize = 20, FontWeight = FontWeights.Bold });
        title.Children.Add(UiKit.Text(L.F("Version {0}", updates.State.CurrentVersion), "Muted"));
        identity.Children.Add(title);
        page.Children.Add(identity);
        page.Children.Add(UpdatesSection.CreateGroup(settings, updates));

        var exit = new Button { Content = L.T("Quit QNotch") };
        AutomationProperties.SetAutomationId(exit, "quit-qnotch");
        exit.Click += (_, _) => { QNotch.Core.Analytics.Track("shell", "quit"); quit(); };
        page.Children.Add(UiKit.SettingsGroup([
            UiKit.SettingsRow(L.T("Quit QNotch"), L.T("Stops QNotch and its running features."), exit)
        ]));

        var tour = new Button { Content = L.T("Show welcome tour") };
        AutomationProperties.SetAutomationId(tour, "about-welcome-tour");
        tour.Click += (_, _) => { QNotch.Core.Analytics.Track("settings", "tour", "ui"); showTour(); };
        page.Children.Add(UiKit.SettingsGroup([
            UiKit.SettingsRow(L.T("Welcome tour"), L.T("What QNotch does, your features and accounts, in a few steps."), tour),
            UiKit.SettingsRow(L.T("Hover the notch"), L.T("Opens the panel without taking the keyboard. Set Open on to Click in General to open it only by clicking."), new TextBlock()),
            UiKit.SettingsRow(L.T("Click the notch"), L.T("Opens the panel with keyboard control."), new TextBlock()),
            UiKit.SettingsRow(L.T("Escape or click outside"), L.T("Closes the panel and returns focus to your app."), new TextBlock())
        ], title: L.T("Using QNotch")));
        return page;
    }
}
