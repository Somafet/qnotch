using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Theme;

namespace QNotch.Modules.Weather;

/// <summary>Settings section: search for a place on yr.no, units, and the temperature in the pill.</summary>
internal static class WeatherSection
{
    public static FrameworkElement Create(ModuleContext ctx, WeatherState s, WeatherService svc)
    {
        var set = svc.Settings;
        var page = UiKit.Page("Weather");

        var current = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxWidth = 280, TextAlignment = TextAlignment.Right };
        page.Children.Add(UiKit.Row("Place", null, current));

        var box = new TextBox { Width = 200, MaxLength = 100, ToolTip = "Town or place name" };
        var search = new Button { Content = "Search", Style = (Style)Application.Current.FindResource("AccentButton"), Margin = new Thickness(8, 0, 0, 0) };
        var searchRow = new StackPanel { Orientation = Orientation.Horizontal };
        searchRow.Children.Add(box);
        searchRow.Children.Add(search);
        page.Children.Add(UiKit.Row("Find a place", "Searches the places yr.no knows. Pick one from the list.", searchRow));

        var result = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, -8, 0, 16), Visibility = Visibility.Collapsed };
        page.Children.Add(result);
        var list = new ListBox { Margin = new Thickness(0, -8, 0, 16), Visibility = Visibility.Collapsed };
        page.Children.Add(list);

        var metric = new RadioButton { Style = (Style)Application.Current.FindResource("SegmentButton"), Content = "°C, m/s", GroupName = "weather-units", FontSize = 12, IsChecked = set.Units == WeatherUnits.Metric };
        var imperial = new RadioButton { Style = (Style)Application.Current.FindResource("SegmentButton"), Content = "°F, mph", GroupName = "weather-units", FontSize = 12, IsChecked = set.Units == WeatherUnits.Imperial };
        void Units(WeatherUnits u) { QNotch.Core.Analytics.Track("settings", "change", target: "weather_units"); set.Units = u; ctx.Settings.Save("weather", set); svc.Reformat(); }
        metric.Checked += (_, _) => Units(WeatherUnits.Metric);
        imperial.Checked += (_, _) => Units(WeatherUnits.Imperial);
        var units = new StackPanel { Orientation = Orientation.Horizontal };
        units.Children.Add(metric);
        units.Children.Add(imperial);
        page.Children.Add(UiKit.Row("Units", null, units));

        page.Children.Add(UiKit.Row("Show in the pill", "The temperature and sky next to the system stats.",
            UiKit.Toggle(set.ShowInPill, v => { QNotch.Core.Analytics.Track("settings", "change", target: "weather_show_in_pill", enabled: v);  set.ShowInPill = v; ctx.Settings.Save("weather", set); svc.Reformat(); })));

        var refresh = new Button { Content = "Refresh now" };
        refresh.Click += (_, _) => { QNotch.Core.Analytics.Track("weather", "refresh", "ui"); svc.Refresh(); };
        page.Children.Add(UiKit.Row("Forecast", "Refreshed about every 30 minutes, when MET Norway publishes a new run. The last one is kept on disk for offline use.", refresh));

        var credit = UiKit.Text("Forecasts from yr.no, made by the Norwegian Meteorological Institute (MET Norway) and NRK. Weather data under CC BY 4.0, symbols by yr.no under MIT.", "Muted");
        credit.Margin = new Thickness(0, 8, 0, 0);
        page.Children.Add(credit);

        void Show(string text, string brushKey)
        {
            result.Text = text;
            result.SetResourceReference(TextBlock.ForegroundProperty, brushKey);
            result.Visibility = Visibility.Visible;
        }

        void Sync()
        {
            var p = set.Place;
            var (text, brush) = p is null ? ("No place picked", "TextTertiaryBrush")
                : s.Status switch
                {
                    WeatherStatus.Ready when s.Stale => ($"{Label(p)}. {s.Message}", "WarningBrush"),
                    WeatherStatus.Ready => ($"{Label(p)}. {s.UpdatedText}.", "SuccessBrush"),
                    WeatherStatus.Error => ($"{Label(p)}. {s.Message}", "DangerBrush"),
                    _ => ($"{Label(p)}. Fetching the forecast", "TextSecondaryBrush"),
                };
            current.Text = text;
            current.SetResourceReference(TextBlock.ForegroundProperty, brush);
            refresh.IsEnabled = p is not null && !s.Refreshing;
        }
        void OnState(object? _, System.ComponentModel.PropertyChangedEventArgs e) => Sync();
        page.Loaded += (_, _) => { s.PropertyChanged += OnState; Sync(); }; // unsubscribed on Unloaded so a closed settings window can be collected
        page.Unloaded += (_, _) => s.PropertyChanged -= OnState;
        Sync();

        async void Search()
        {
            QNotch.Core.Analytics.Track("weather", "search");
            var q = box.Text.Trim();
            if (q.Length < 2) { Show("Type at least two letters.", "WarningBrush"); return; }
            if (ctx.Settings.ReadOnly) return; // snapshot run: no requests
            search.IsEnabled = false;
            list.Visibility = Visibility.Collapsed;
            Show("Searching", "TextSecondaryBrush");
            try
            {
                var found = await WeatherService.SearchAsync(q);
                list.Items.Clear();
                foreach (var p in found) list.Items.Add(Row(p));
                if (found.Count == 0) Show($"yr.no knows no place called \"{q}\".", "WarningBrush");
                else { result.Visibility = Visibility.Collapsed; list.Visibility = Visibility.Visible; }
            }
            catch (WeatherException ex) { Show(ex.Message, "DangerBrush"); }
            finally { search.IsEnabled = true; }
        }
        search.Click += (_, _) => {  Search(); };
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; Search(); } };

        ListBoxItem Row(WeatherPlace p)
        {
            var row = new StackPanel();
            row.Children.Add(new TextBlock { Text = p.Name, FontSize = 13 });
            if (p.Detail.Length > 0) row.Children.Add(UiKit.Text(p.Detail, "Muted"));
            var item = new ListBoxItem { Content = row, Cursor = Cursors.Hand, Padding = new Thickness(10, 6, 10, 6) };
            item.PreviewMouseLeftButtonUp += (_, _) => Pick(p);
            item.KeyDown += (_, e) => { if (e.Key == Key.Enter) Pick(p); };
            return item;
        }

        void Pick(WeatherPlace p)
        {
            list.Visibility = Visibility.Collapsed;
            list.Items.Clear();
            box.Clear();
            svc.SetPlace(p);
            Show($"Showing the forecast for {Label(p)}.", "SuccessBrush");
        }

        return page;
    }

    static string Label(WeatherPlace p) => p.Detail.Length > 0 ? $"{p.Name}, {p.Detail}" : p.Name;
}
