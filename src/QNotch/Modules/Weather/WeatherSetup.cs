using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using QNotch.Theme;

namespace QNotch.Modules.Weather;

/// <summary>
/// The Weather row of the welcome tour's Connect step: the same yr.no place search as Settings, Weather. Works before the module exists:
/// it saves the place in weather.json and a running module picks it up through <see cref="PlaceChosen"/>.
/// </summary>
internal static class WeatherSetup
{
    /// <summary>A place was picked in the tour. A running Weather module shows its forecast (UI thread).</summary>
    public static event Action<WeatherPlace>? PlaceChosen;

    public static SetupRow Create(SetupContext ctx)
    {
        var set = ctx.Settings.Get<WeatherSettings>("weather");
        SetupRow? row = null;
        var status = new TextBlock();
        void Status(string text, string brush)
        {
            status.Text = text;
            status.SetResourceReference(TextBlock.ForegroundProperty, brush);
        }
        void ShowPlace(WeatherPlace? p)
        {
            if (p is null) Status("No place picked", "TextTertiaryBrush");
            else Status(Label(p), "SuccessBrush");
        }

        var box = new TextBox { Width = 170, MaxLength = 100, ToolTip = "Town or place name" };
        AutomationProperties.SetName(box, "Find a place");
        var hint = new TextBlock { Text = "Find a place", IsHitTestVisible = false, Margin = new Thickness(11, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        hint.SetResourceReference(TextBlock.ForegroundProperty, "TextTertiaryBrush");
        // The hint steps aside while the box has the caret, so it never sits under it.
        void ShowHint() => hint.Visibility = box.Text.Length == 0 && !box.IsKeyboardFocused ? Visibility.Visible : Visibility.Collapsed;
        box.TextChanged += (_, _) => ShowHint();
        box.GotKeyboardFocus += (_, _) => ShowHint();
        box.LostKeyboardFocus += (_, _) => ShowHint();
        var field = new Grid();
        field.Children.Add(box);
        field.Children.Add(hint);
        var search = new Button { Content = "Search", Margin = new Thickness(8, 0, 0, 0) };
        var action = new StackPanel { Orientation = Orientation.Horizontal };
        action.Children.Add(field);
        action.Children.Add(search);

        var list = new ListBox { Margin = new Thickness(0, 8, 0, 0), MaxHeight = 150, Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(list, "Places");

        async void Search()
        {
            QNotch.Core.Analytics.Track("weather", "search");
            var q = box.Text.Trim();
            if (q.Length < 2) { Status("Type at least two letters.", "WarningBrush"); return; }
            if (ctx.Demo) return;
            search.IsEnabled = false;
            list.Visibility = Visibility.Collapsed;
            Status("Searching", "TextSecondaryBrush");
            try
            {
                var found = await WeatherService.SearchAsync(q);
                list.Items.Clear();
                foreach (var p in found.Take(6)) list.Items.Add(Row(p));
                if (found.Count == 0) Status($"yr.no knows no place called \"{q}\".", "WarningBrush");
                else { ShowPlace(set.Place); list.Visibility = Visibility.Visible; }
            }
            catch (WeatherException ex) { Status(ex.Message, "DangerBrush"); }
            finally { search.IsEnabled = true; }
        }
        search.Click += (_, _) => {  Search(); };
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; Search(); } };

        ListBoxItem Row(WeatherPlace p)
        {
            var text = new TextBlock { TextTrimming = TextTrimming.CharacterEllipsis };
            text.Inlines.Add(new System.Windows.Documents.Run(p.Name) { FontSize = 12.5 });
            if (p.Detail.Length > 0)
            {
                var detail = new System.Windows.Documents.Run("  " + p.Detail) { FontSize = 11.5 };
                detail.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "TextTertiaryBrush");
                text.Inlines.Add(detail);
            }
            var item = new ListBoxItem { Content = text, Cursor = Cursors.Hand, Padding = new Thickness(10, 5, 10, 5) };
            AutomationProperties.SetName(item, Label(p));
            item.PreviewMouseLeftButtonUp += (_, _) => Pick(p);
            item.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; Pick(p); } };
            return item;
        }

        void Pick(WeatherPlace p)
        {
            list.Visibility = Visibility.Collapsed;
            list.Items.Clear();
            box.Clear();
            set.Place = p;
            ctx.Settings.Save("weather", set);
            PlaceChosen?.Invoke(p);
            ShowPlace(p);
            row?.Success();
        }

        // Snapshot: a chosen place, no file or request.
        ShowPlace(ctx.Demo ? new WeatherPlace { Name = "Berlin", Detail = "Germany" } : set.Place);
        return row = new SetupRow("Weather", WeatherModule.Sun, status, action, list);
    }

    static string Label(WeatherPlace p) => p.Detail.Length > 0 ? $"{p.Name}, {p.Detail}" : p.Name;
}
