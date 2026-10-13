using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using QNotch.Core;
using QNotch.Core.Updates;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

internal static class UpdatesSection
{
    public const string UpdateGlyph = "\uE895";

    public static FrameworkElement Create(GeneralSettings settings, UpdateService updates)
    {
        var page = UiKit.Page("Updates");
        var choice = new StackPanel { Margin = new Thickness(0, 0, 0, 24) };
        choice.Children.Add(UiKit.Text("Keep automatic update checks enabled?", "Title"));
        choice.Children.Add(new TextBlock
        {
            Text = "QNotch checks GitHub for new versions automatically. You decide when to install each update. You can change this preference below at any time.",
            Style = (Style)Application.Current.FindResource("Muted"), TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 8, 0, 12),
        });
        var choices = new StackPanel { Orientation = Orientation.Horizontal };
        var keep = new Button { Content = "Keep enabled", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(0, 0, 8, 0) };
        var turnOff = new Button { Content = "Turn off" };
        AutomationProperties.SetAutomationId(keep, "updates-keep-enabled");
        AutomationProperties.SetAutomationId(turnOff, "updates-turn-off");
        keep.Click += (_, _) => updates.ChooseAutomaticChecks(true);
        turnOff.Click += (_, _) => updates.ChooseAutomaticChecks(false);
        choices.Children.Add(keep); choices.Children.Add(turnOff);
        choice.Children.Add(choices);
        page.Children.Add(UiKit.BindVisible(choice, updates.State, nameof(UpdateState.NeedsPreferenceChoice)));
        var toggle = UiKit.Toggle();
        toggle.SetBinding(System.Windows.Controls.Primitives.ToggleButton.IsCheckedProperty,
            new Binding(nameof(GeneralSettings.CheckForUpdates)) { Source = settings, Mode = BindingMode.TwoWay });
        AutomationProperties.SetName(toggle, "Check for updates automatically");
        AutomationProperties.SetAutomationId(toggle, "updates-auto-check");
        page.Children.Add(UiKit.Row("Check for updates automatically",
            "Checks GitHub after startup and every six hours. Updates install only when you choose Update and restart.", toggle));

        var check = new Button { Content = "Check now", Padding = new Thickness(14, 6, 14, 6) };
        AutomationProperties.SetAutomationId(check, "updates-check");
        UiKit.Bind(check, UIElement.IsEnabledProperty, updates.State, nameof(UpdateState.CanCheck));
        check.Click += async (_, _) => await updates.CheckAsync();
        page.Children.Add(UiKit.Row("Current version", $"QNotch {updates.State.CurrentVersion}", check));

        var status = UiKit.Bind(UiKit.Text(""), TextBlock.TextProperty, updates.State, nameof(UpdateState.Status));
        status.Margin = new Thickness(0, 0, 0, 16);
        page.Children.Add(status);

        var install = new Button { Content = "Update and restart", Style = (Style)Application.Current.FindResource("AccentButton") };
        AutomationProperties.SetAutomationId(install, "updates-install");
        UiKit.Bind(install, UIElement.IsEnabledProperty, updates.State, nameof(UpdateState.CanUpdate));
        install.Click += async (_, _) => await updates.InstallAsync();
        var row = UiKit.Row("New version", null, install);
        // Replace the fixed row label with the version text.
        var label = (TextBlock)((StackPanel)row.Children[0]).Children[0];
        UiKit.Bind(label, TextBlock.TextProperty, updates.State, nameof(UpdateState.AvailableText));
        page.Children.Add(UiKit.BindVisible(row, updates.State, nameof(UpdateState.HasUpdate)));

        var progress = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6, Margin = new Thickness(0, 0, 0, 16) };
        UiKit.Bind(progress, System.Windows.Controls.Primitives.RangeBase.ValueProperty, updates.State, nameof(UpdateState.DownloadPercent));
        page.Children.Add(UiKit.BindVisible(progress, updates.State, nameof(UpdateState.IsDownloading)));
        page.Children.Add(UiKit.Text("Your settings and saved history stay in place. The previous executable is kept as a backup.", "Muted"));

        var notes = new Button { Content = "Release notes on GitHub", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 16, 0, 0) };
        notes.Click += (_, _) =>
        {
            try { Process.Start(new ProcessStartInfo(UpdateRelease.Repository + "/releases") { UseShellExecute = true }); }
            catch (Exception ex) { Log.Warn("Opening the QNotch releases page failed", ex); }
        };
        page.Children.Add(notes);
        return page;
    }

    public static FrameworkElement Indicator(UpdateService updates, Action openSettings)
    {
        var button = new Button
        {
            Content = UpdateGlyph,
            Style = (Style)Application.Current.FindResource("IconButton"),
            Width = 22, Height = 22,
        };
        button.SetResourceReference(Control.ForegroundProperty, "AccentBrush");
        UiKit.Bind(button, FrameworkElement.ToolTipProperty, updates.State, nameof(UpdateState.AvailableText));
        AutomationProperties.SetAutomationId(button, "updates-available");
        button.Click += (_, e) => { e.Handled = true; openSettings(); };
        return UiKit.BindVisible(button, updates.State, nameof(UpdateState.HasUpdate));
    }
}
