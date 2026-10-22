using System.Windows;
using System.Windows.Controls;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Theme;

namespace QNotch.Shell.Settings;

/// <summary>Settings, Features: one switch per module. A module that is off is never created, so it costs nothing. Changes apply on restart.</summary>
public static class FeaturesSection
{
    public static FrameworkElement Create(GeneralSettings gs, SettingsStore store, IReadOnlyList<ModuleInfo> modules,
        IReadOnlySet<string> bootDisabled, Action restart, CardLayout layout, Registry<TabDescriptor> tabs, Registry<SegmentDescriptor> segments)
    {
        var page = UiKit.Page("Features");
        var intro = UiKit.Text("Turn off what you do not use. A feature that is off is never loaded and costs nothing.", "Muted");
        intro.Margin = new Thickness(0, -6, 0, 16);
        page.Children.Add(intro);
        page.Children.Add(UiKit.Text("Presentation changes apply now. Turning a whole feature on or off requires a restart. Hidden items keep their saved order.", "Muted"));
        var presentation = store.Get<WindowsPresentationSettings>("windows-presentation");

        var bar = RestartBar(restart);
        void Sync() => bar.Visibility = modules.Where(m => !m.IsEnabled(gs)).Select(m => m.Id).ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(bootDisabled) ? Visibility.Collapsed : Visibility.Visible;

        foreach (var info in modules)
        {
            var id = info.Id;
            var on = info.IsEnabled(gs);
            var toggle = UiKit.Toggle(on, v =>
            {
                info.SetEnabled(gs, v);
                store.Save("general", gs);
                Sync();
            });
            System.Windows.Automation.AutomationProperties.SetAutomationId(toggle, "feature-" + id);
            page.Children.Add(UiKit.Row(info.Title, info.Description, toggle));
            void Choice(string key, string title, string hint, bool value, Action<bool> set)
            {
                var control = UiKit.Toggle(value, set);
                System.Windows.Automation.AutomationProperties.SetAutomationId(control, "presentation-" + key);
                var row = UiKit.Row(title, hint, control);
                row.Margin = new Thickness(20, 0, 0, 0);
                page.Children.Add(row);
            }
            foreach (var card in layout.Ordered.Where(c => layout.OwnerOf(c.Id) == id))
                Choice("card-" + card.Id, "Show on Home: " + card.Title, "Keep the feature running while its card is hidden.", layout.IsVisible(card.Id), v => layout.SetVisible(card.Id, v));
            foreach (var tab in tabs.Items.Where(t => tabs.OwnerOf(t.Id) == id))
                Choice("tab-" + tab.Id, "Show as a tab", "Hidden tabs cannot be opened by search, shortcuts or cards.", presentation.TabVisible(tab.Id), v => presentation.SetTab(tab.Id, v));
            var notch = segments.Items.Where(s => segments.OwnerOf(s.Id) == id && s.Slot != SegmentSlot.GameBar).ToList();
            if (notch.Count > 0)
                Choice("notch-" + id, "Show in the notch", "Pill and glance indicators. Game bar choices stay in Settings, Game mode.",
                    notch.Any(s => s.Presented?.Invoke() ?? presentation.SegmentVisible(s.Id)), v =>
                    {
                        foreach (var segment in notch) segment.SetPresented?.Invoke(v);
                        presentation.SetSegments(notch.Where(s => s.SetPresented is null).Select(s => s.Id), v);
                    });
            if (bootDisabled.Contains(id))
                page.Children.Add(UiKit.Text("Enable and restart to configure this feature's presentation.", "Muted"));
        }
        page.Children.Add(bar);
        Sync();
        return page;
    }

    static Border RestartBar(Action restart)
    {
        var text = new TextBlock { Text = "Restart QNotch to apply your changes.", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Content = "Restart now", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(16, 0, 0, 0) };
        button.Click += (_, _) => restart();
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(button, 1);
        row.Children.Add(text);
        row.Children.Add(button);
        var bar = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 8, 8), Margin = new Thickness(0, 8, 0, 0), Child = row, Visibility = Visibility.Collapsed };
        bar.SetResourceReference(Border.BackgroundProperty, "ControlBrush");
        return bar;
    }
}
