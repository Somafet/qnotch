using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
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
        page.Children.Add(UiKit.SettingsIntro("Choose what runs and where it appears. Placement applies immediately. Turning a feature on or off requires a restart."));
        var presentation = store.Get<WindowsPresentationSettings>("windows-presentation");

        var bar = RestartBar(restart);
        page.Children.Add(bar);
        var refresh = new List<Action>();
        void Sync()
        {
            bar.Visibility = modules.Where(m => !m.IsEnabled(gs)).Select(m => m.Id).ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(bootDisabled) ? Visibility.Collapsed : Visibility.Visible;
            foreach (var update in refresh) update();
        }

        foreach (var info in modules)
        {
            var id = info.Id;
            var on = info.IsEnabled(gs);
            var toggle = UiKit.Toggle(on, v =>
            {
                QNotch.Core.Analytics.Track("settings", "change_feature", target: id, enabled: v); info.SetEnabled(gs, v);
                store.Save("general", gs);
                Sync();
            });
            AutomationProperties.SetAutomationId(toggle, "feature-" + id);
            AutomationProperties.SetName(toggle, "Enable " + info.Title);
            var rows = new List<FrameworkElement> { FeatureHeader(info, toggle) };
            void Choice(string key, string title, string hint, bool value, Action<bool> set)
            {
                var control = UiKit.Toggle(value, v => { QNotch.Core.Analytics.Track("settings", "change_presentation", target: id, enabled: v); set(v); });
                AutomationProperties.SetAutomationId(control, "presentation-" + key);
                AutomationProperties.SetName(control, info.Title + ": " + title);
                AutomationProperties.SetHelpText(control, hint);
                control.ToolTip = hint;
                var row = UiKit.SettingsRow(title, null, control);
                row.Margin = new Thickness(60, 6, 16, 6);
                rows.Add(row);
            }
            var cards = layout.Ordered.Where(c => layout.OwnerOf(c.Id) == id).ToList();
            foreach (var card in cards)
                Choice("card-" + card.Id, cards.Count == 1 ? "Show on Home" : "Show " + card.Title + " on Home", "Keep the feature running while its card is hidden. Hidden cards keep their saved order.", layout.IsVisible(card.Id), v => layout.SetVisible(card.Id, v));
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
            var group = UiKit.SettingsGroup(rows, footer: bootDisabled.Contains(id) ? "Off. Enable and restart to choose where it appears. Your placement choices are kept." : null);
            AutomationProperties.SetAutomationId(group, "feature-group-" + id);
            // Keep restart reachable next to the changed feature, even far down this page.
            var apply = new Button { Content = "Restart now", Style = (Style)Application.Current.FindResource("LinkButton") };
            AutomationProperties.SetAutomationId(apply, "feature-restart-" + id);
            AutomationProperties.SetName(apply, "Restart to apply " + info.Title);
            apply.Click += (_, _) => { QNotch.Core.Analytics.Track("settings", "setup_apply", "ui"); restart(); };
            var pending = UiKit.SettingsRow("", null, apply);
            pending.Margin = new Thickness(4, 8, 4, 0);
            var status = ((StackPanel)pending.Children[0]).Children.OfType<TextBlock>().First();
            status.FontSize = 12;
            status.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
            refresh.Add(() =>
            {
                var changed = info.IsEnabled(gs) == bootDisabled.Contains(id);
                pending.Visibility = changed ? Visibility.Visible : Visibility.Collapsed;
                status.Text = info.IsEnabled(gs) ? "Will turn on after restart." : "Will turn off after restart.";
            });
            group.Children.Add(pending);
            page.Children.Add(group);
        }
        Sync();
        return page;
    }

    static Grid FeatureHeader(ModuleInfo info, CheckBox toggle)
    {
        var header = new Grid { Margin = new Thickness(16, 14, 16, 14) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        header.ColumnDefinitions.Add(new ColumnDefinition());
        var icon = new Border { Width = 32, Height = 32, CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        icon.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        var glyph = UiKit.Glyph(info.Glyph, 16, "AccentBrush");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        icon.Child = glyph;
        var row = UiKit.SettingsRow(info.Title, info.Description, toggle);
        row.Margin = new Thickness(0);
        var title = ((StackPanel)row.Children[0]).Children.OfType<TextBlock>().First();
        title.FontWeight = FontWeights.SemiBold;
        title.FontSize = 14;
        Grid.SetColumn(row, 1);
        header.Children.Add(icon);
        header.Children.Add(row);
        return header;
    }

    static Border RestartBar(Action restart)
    {
        var text = new TextBlock { Text = "Feature changes are ready to apply.", TextWrapping = TextWrapping.Wrap, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        var button = new Button { Content = "Restart now", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(16, 0, 0, 0) };
        button.Click += (_, _) => restart();
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(button, 1);
        row.Children.Add(text);
        row.Children.Add(button);
        var bar = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 12, 12, 12), Margin = new Thickness(0, 0, 0, 20), Child = row, Visibility = Visibility.Collapsed };
        bar.SetResourceReference(Border.BackgroundProperty, "AccentSoftBrush");
        return bar;
    }
}
