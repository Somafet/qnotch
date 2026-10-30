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
        var page = UiKit.Page("About");
        var identity = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 22) };
        identity.Children.Add(new Image { Source = AppIcon.Render(120), Width = 60, Height = 60, Margin = new Thickness(0, 0, 14, 0) });
        var title = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(new TextBlock { Text = "QNotch", FontSize = 20, FontWeight = FontWeights.Bold });
        title.Children.Add(UiKit.Text($"Version {updates.State.CurrentVersion}", "Muted"));
        identity.Children.Add(title);
        page.Children.Add(identity);
        page.Children.Add(UpdatesSection.CreateGroup(settings, updates));

        var exit = new Button { Content = "Quit QNotch" };
        AutomationProperties.SetAutomationId(exit, "quit-qnotch");
        exit.Click += (_, _) => quit();
        page.Children.Add(UiKit.SettingsGroup([
            UiKit.SettingsRow("Quit QNotch", "Stops QNotch and its running features.", exit)
        ]));

        var tour = new Button { Content = "Show welcome tour" };
        AutomationProperties.SetAutomationId(tour, "about-welcome-tour");
        tour.Click += (_, _) => showTour();
        page.Children.Add(UiKit.SettingsGroup([
            UiKit.SettingsRow("Welcome tour", "What QNotch does, your features and accounts, in a few steps.", tour),
            UiKit.SettingsRow("Hover the notch", "Opens the panel without taking the keyboard.", new TextBlock()),
            UiKit.SettingsRow("Click the notch", "Opens the panel with keyboard control.", new TextBlock()),
            UiKit.SettingsRow("Escape or click outside", "Closes the panel and returns focus to your app.", new TextBlock())
        ], title: "Using QNotch"));
        return page;
    }
}
