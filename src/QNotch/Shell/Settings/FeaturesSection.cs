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
        IReadOnlySet<string> bootDisabled, Action restart)
    {
        var page = UiKit.Page("Features");
        var intro = UiKit.Text("Turn off what you do not use. A feature that is off is never loaded and costs nothing.", "Muted");
        intro.Margin = new Thickness(0, -6, 0, 16);
        page.Children.Add(intro);

        var bar = RestartBar(restart);
        void Sync() => bar.Visibility = gs.DisabledModules.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(bootDisabled) ? Visibility.Collapsed : Visibility.Visible;

        foreach (var info in modules)
        {
            var id = info.Id;
            var on = !gs.DisabledModules.Contains(id, StringComparer.OrdinalIgnoreCase);
            page.Children.Add(UiKit.Row(info.Title, info.Description, UiKit.Toggle(on, v =>
            {
                gs.DisabledModules.RemoveAll(x => string.Equals(x, id, StringComparison.OrdinalIgnoreCase));
                if (!v) gs.DisabledModules.Add(id);
                store.Save("general", gs);
                Sync();
            })));
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
