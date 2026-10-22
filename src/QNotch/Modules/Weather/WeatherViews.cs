using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QNotch.Core;
using QNotch.Shell;
using QNotch.Theme;

namespace QNotch.Modules.Weather;

/// <summary>The yr.no weather symbols (github.com/metno/weathericons, MIT), 96 px PNGs in Icons/, decoded once each and frozen.</summary>
internal static class WeatherIcons
{
    static readonly Dictionary<string, ImageSource?> Cache = [];

    public static ImageSource? Get(string symbol)
    {
        if (symbol.Length == 0) return null;
        if (Cache.TryGetValue(symbol, out var img)) return img;
        // The icon set spells two codes with a double s.
        var file = symbol.Replace("lightsleetshowersandthunder", "lightssleetshowersandthunder").Replace("lightsnowshowersandthunder", "lightssnowshowersandthunder");
        try
        {
            var b = new BitmapImage();
            b.BeginInit();
            b.UriSource = new Uri($"pack://application:,,,/Modules/Weather/Icons/{file}.png");
            b.CacheOption = BitmapCacheOption.OnLoad;
            b.EndInit();
            b.Freeze();
            img = b;
        }
        catch (Exception ex) { Log.Warn($"No weather icon for {symbol}", ex); img = null; }
        return Cache[symbol] = img;
    }

    public static Image Image(double size)
    {
        var i = new Image { Width = size, Height = size, Stretch = Stretch.Uniform };
        RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality);
        return i;
    }

    /// <summary>An image bound to a symbol code property of <paramref name="source"/>.</summary>
    public static Image Bound(double size, object source, string path) => UiKit.Bind(Image(size), System.Windows.Controls.Image.SourceProperty, source, path, ToImage.Instance);

    sealed class ToImage : IValueConverter
    {
        public static readonly ToImage Instance = new();
        public object? Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is string s ? Get(s) : null;
        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
    }
}

/// <summary>Current conditions at Small; current conditions and the next days at Medium, with explicit unavailable states.</summary>
internal sealed class WeatherCard : Grid
{
    readonly WeatherState _s;
    readonly FrameworkElement _ready, _noPlace, _loading, _error;
    readonly UniformGrid _days = new() { Rows = 1, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _place = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBlock _errorText = UiKit.Text("", "Muted");

    public WeatherCard(WeatherState state, WeatherService svc, IShell shell)
    {
        _s = state;
        _ready = BuildReady(svc, shell);
        _noPlace = Centered("Pick a place", "Search for your town in Settings to see its forecast from yr.no.",
            Action("Pick a place", () => shell.OpenSettings("weather")));
        _loading = Centered("Loading forecast", "Fetching the forecast from yr.no.", null);
        _error = Centered("Could not load the forecast", "", Action("Retry", svc.Refresh), _errorText);
        foreach (var e in new[] { _ready, _noPlace, _loading, _error }) Children.Add(e);
        _s.PropertyChanged += OnChanged;
        Sync();
    }

    void OnChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(WeatherState.Status) or nameof(WeatherState.Days) or nameof(WeatherState.Message) or nameof(WeatherState.Stale)
            or nameof(WeatherState.PlaceName) or nameof(WeatherState.DetailText) or nameof(WeatherState.UpdatedText)) Sync();
    }

    void Sync()
    {
        var st = _s.Status;
        _ready.Visibility = st == WeatherStatus.Ready ? Visibility.Visible : Visibility.Collapsed;
        _noPlace.Visibility = st == WeatherStatus.NoPlace ? Visibility.Visible : Visibility.Collapsed;
        _loading.Visibility = st == WeatherStatus.Loading ? Visibility.Visible : Visibility.Collapsed;
        _error.Visibility = st == WeatherStatus.Error ? Visibility.Visible : Visibility.Collapsed;
        if (st == WeatherStatus.Error) _errorText.Text = _s.Message;
        if (st != WeatherStatus.Ready) return;

        // A failed refresh replaces the place line with the reason, in the warning color.
        var warn = _s.Stale && _s.Message.Length > 0;
        _place.Text = warn ? _s.Message : _s.DetailText.Length > 0 ? $"{_s.PlaceName} · {_s.DetailText}" : _s.PlaceName;
        _place.ToolTip = warn ? $"{_s.Message} {_s.UpdatedText}." : $"{_s.PlaceName} · {_s.UpdatedText}";
        _place.SetResourceReference(TextBlock.ForegroundProperty, warn ? "WarningBrush" : "TextTertiaryBrush");

        _days.Children.Clear();
        _days.Columns = Math.Max(1, _s.Days.Count);
        foreach (var d in _s.Days) _days.Children.Add(Day(d));
    }

    FrameworkElement BuildReady(WeatherService svc, IShell shell)
    {
        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var open = new Button { Style = (Style)Application.Current.FindResource("IconButton"), Content = Glyphs.Link, Width = 24, Height = 24, ToolTip = "Open on yr.no",
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(4, -2, -4, 0) };
        open.Click += (_, _) => { svc.OpenYr(); shell.ClosePanel(); };
        Grid.SetColumn(open, 2);
        root.Children.Add(open);

        // Now: icon, temperature and condition, then the place line.
        var now = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var top = new DockPanel();
        var icon = WeatherIcons.Bound(44, _s, nameof(WeatherState.Symbol));
        icon.Margin = new Thickness(-2, 0, 8, 0);
        top.Children.Add(icon);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var temp = new TextBlock { FontSize = 26, FontWeight = FontWeights.SemiBold, LineHeight = 30, LineStackingStrategy = LineStackingStrategy.BlockLineHeight };
        UiKit.Bind(temp, TextBlock.TextProperty, _s, nameof(WeatherState.TempText));
        var cond = new TextBlock { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
        cond.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");
        UiKit.Bind(cond, TextBlock.TextProperty, _s, nameof(WeatherState.ConditionText));
        UiKit.Bind(cond, ToolTipProperty, _s, nameof(WeatherState.ConditionText));
        texts.Children.Add(temp);
        texts.Children.Add(cond);
        top.Children.Add(texts);
        now.Children.Add(top);
        now.Children.Add(_place);
        root.Children.Add(now);

        Grid.SetColumn(_days, 1);
        root.Children.Add(_days);
        SizeChanged += (_, _) =>
        {
            var small = ActualWidth < 300;
            _days.Visibility = small ? Visibility.Collapsed : Visibility.Visible;
            root.ColumnDefinitions[0].Width = small ? new GridLength(1, GridUnitType.Star) : new GridLength(176);
            root.ColumnDefinitions[1].Width = small ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        };
        return root;
    }

    static FrameworkElement Day(WeatherDay d)
    {
        var p = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, ToolTip = d.Tip, Background = Brushes.Transparent };
        var name = UiKit.Text(d.Name, "Muted");
        name.HorizontalAlignment = HorizontalAlignment.Center;
        p.Children.Add(name);
        var img = WeatherIcons.Image(30);
        img.Source = WeatherIcons.Get(d.Symbol);
        img.Margin = new Thickness(0, 3, 0, 3);
        p.Children.Add(img);
        var t = new TextBlock { FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
        t.Inlines.Add(new System.Windows.Documents.Run(d.High) { FontWeight = FontWeights.SemiBold });
        var low = new System.Windows.Documents.Run(" " + d.Low);
        low.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "TextTertiaryBrush");
        t.Inlines.Add(low);
        p.Children.Add(t);
        return p;
    }

    static Button Action(string text, System.Action onClick)
    {
        var b = new Button { Content = text, Style = (Style)Application.Current.FindResource("AccentButton"), Padding = new Thickness(12, 5, 12, 5), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Sun icon, title and message on the left, optional action button on the right.</summary>
    static FrameworkElement Centered(string title, string message, Button? action, TextBlock? messageBlock = null)
    {
        var row = new Grid { VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        row.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var icon = UiKit.Glyph(WeatherModule.Sun, 22, "TextTertiaryBrush");
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 12, 0);
        row.Children.Add(icon);
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 230 };
        text.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = title });
        var m = messageBlock ?? UiKit.Text(message, "Muted");
        m.Margin = new Thickness(0, 2, 0, 0);
        m.MaxHeight = 42;
        m.TextTrimming = TextTrimming.CharacterEllipsis;
        text.Children.Add(m);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        if (action is not null) { Grid.SetColumn(action, 2); row.Children.Add(action); }
        row.SizeChanged += (_, _) =>
        {
            var small = row.ActualWidth < 300;
            icon.Visibility = small ? Visibility.Collapsed : Visibility.Visible;
            m.Visibility = small && action is not null ? Visibility.Collapsed : Visibility.Visible;
            m.ToolTip = m.Text;
            text.ToolTip = m.Text;
            Grid.SetColumn(text, small ? 0 : 1);
            Grid.SetColumnSpan(text, small ? 3 : 1);
            if (action is not null)
            {
                Grid.SetRow(action, small ? 1 : 0);
                Grid.SetColumn(action, small ? 0 : 2);
                Grid.SetColumnSpan(action, small ? 3 : 1);
                action.HorizontalAlignment = small ? HorizontalAlignment.Left : HorizontalAlignment.Center;
                action.Margin = small ? new Thickness(0, 8, 0, 0) : new Thickness(16, 0, 0, 0);
            }
        };
        return row;
    }
}

/// <summary>Pill and game bar: the symbol and the temperature, collapsed while there is no forecast (or, in the pill, when turned off).</summary>
internal static class WeatherSegments
{
    public static FrameworkElement Pill(WeatherState s) => Segment(s, nameof(WeatherState.PillVisible), 16, gap: true);
    public static FrameworkElement Game(WeatherState s) => Segment(s, nameof(WeatherState.GameVisible), 16, gap: false);

    static FrameworkElement Segment(WeatherState s, string visible, double iconSize, bool gap)
    {
        var icon = WeatherIcons.Bound(iconSize, s, nameof(WeatherState.Symbol));
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 4, 0);
        var text = new TextBlock { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        UiKit.Bind(text, TextBlock.TextProperty, s, nameof(WeatherState.TempText));
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (gap) p.Margin = new Thickness(0, 0, 12, 0); // same gap the stats pill puts between its parts
        p.Children.Add(icon);
        p.Children.Add(text);
        return UiKit.BindVisible(p, s, visible);
    }
}
