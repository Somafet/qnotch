using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using QNotch.Core;
using QNotch.Modules.Github;
using QNotch.Modules.Media;
using QNotch.Modules.Weather;
using QNotch.Shell.Diagnostics;
using MediaState = QNotch.Modules.Media.MediaState;

internal static class CardRenderingChecks
{
    public static void Run()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var app = new Application();
                app.Resources.MergedDictionaries.Add(new ResourceDictionary());
                app.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/QNotch;component/Theme/Styles.xaml") });
                app.Resources["AccentBrush"] = Brushes.CornflowerBlue;
                app.Resources["OnAccentBrush"] = Brushes.White;
                foreach (var theme in new[] { ThemeChoice.Dark, ThemeChoice.Light })
                {
                    app.Resources.MergedDictionaries[0] = new ResourceDictionary { Source = new Uri($"pack://application:,,,/QNotch;component/Theme/Theme.{theme}.xaml") };
                    var weather = new WeatherState { TempText = "−12°", ConditionText = "Heavy rain showers and thunder", PlaceName = "A very long place name", Message = "A long offline error explanation" };
                    var weatherView = new WeatherCard(weather, new WeatherService(null!, weather, new WeatherSettings()), null!);
                    var github = new GithubState { GithubTotalText = "1,234,567 contributions", GithubStreakText = "365 day streak", GithubMessage = "A long offline error explanation" };
                    var githubView = new GithubCard(github, null!, null!);
                    var media = new MediaState(new MediaModule()) { Title = "A long track title that should be trimmed", Artist = "A long artist name", HasTimeline = true, IsReady = true };
                    media.Sessions.Add(new("first", "First app", "First app"));
                    media.Sessions.Add(new("second", "Second app", "Second app"));
                    var mediaView = new MediaCard(media, null!);
                    foreach (var width in new[] { 188d, 416d, 188d, 416d })
                    {
                        foreach (var status in Enum.GetValues<WeatherStatus>())
                        {
                            weather.Status = status;
                            Check(weatherView, width, $"Weather {status}");
                        }
                        foreach (var status in Enum.GetValues<GithubStatus>())
                        {
                            github.GithubStatus = status;
                            Check(githubView, width, $"GitHub {status}");
                        }
                        foreach (var (session, available) in new[] { (true, true), (false, true), (false, false) })
                        {
                            media.HasSession = session;
                            media.IsAvailable = available;
                            Check(mediaView, width, $"Media session={session} available={available}");
                            if (session && width < 300 && Outline.Of(mediaView).Contains("[Slider]", StringComparison.Ordinal))
                                throw new InvalidOperationException("Small Media exposed the full timeline");
                            if (session && Descendants(mediaView).OfType<ListBox>().Any() != (width > 300))
                                throw new InvalidOperationException("Media source picker did not adapt to the selected size");
                        }
                    }
                }
                app.Shutdown();
            }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) throw new InvalidOperationException("Card rendering failed", failure);
    }

    static void Check(FrameworkElement body, double width, string name)
    {
        var size = new Size(width, 96);
        body.Measure(size);
        body.Arrange(new Rect(size));
        body.UpdateLayout();
        Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
        var checkedElements = 0;
        foreach (var element in Descendants(body))
        {
            if (element is not TextBlock and not Button) continue;
            checkedElements++;
            var at = element.TranslatePoint(new Point(), body);
            if (at.X < -4 || at.Y < -3 || at.X + element.ActualWidth > width + 4 || at.Y + element.ActualHeight > 99)
                throw new InvalidOperationException($"{name}, width {width}: {element.GetType().Name} exceeds the body at {at}, size {element.RenderSize}");
        }
        if (checkedElements == 0) throw new InvalidOperationException($"{name} rendered no content");
    }

    static IEnumerable<FrameworkElement> Descendants(DependencyObject parent)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is UIElement ui && ui.Visibility != Visibility.Visible) continue;
            if (child is FrameworkElement element) yield return element;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }
}
