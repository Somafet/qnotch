using QNotch.Core;

namespace QNotch.Modules.Weather;

public enum WeatherUnits { Metric, Imperial }

public sealed class WeatherSettings
{
    /// <summary>The place the forecast is for; null until the user picks one in Settings, Weather.</summary>
    public WeatherPlace? Place { get; set; }
    public WeatherUnits Units { get; set; } = WeatherUnits.Metric;
    public bool ShowInPill { get; set; } = true;
}

/// <summary>A place from the yr.no location search.</summary>
public sealed class WeatherPlace
{
    /// <summary>yr.no location id, for example "2-3054643".</summary>
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    /// <summary>"Budapest, Hungary": region and country, whichever differ from the name.</summary>
    public string Detail { get; set; } = "";
    public double Lat { get; set; }
    public double Lon { get; set; }
    public int? Elevation { get; set; }
    /// <summary>IANA time zone of the place, so the days follow its midnight.</summary>
    public string TimeZone { get; set; } = "";
    /// <summary>"Hungary/Budapest/Budapest", the readable tail of the yr.no page address.</summary>
    public string UrlPath { get; set; } = "";

    public string YrUrl() => "https://www.yr.no/en/forecast/daily-table/" + Uri.EscapeDataString(Id)
        + (UrlPath.Length > 0 ? "/" + string.Join('/', UrlPath.Split('/').Select(Uri.EscapeDataString)) : "");

    public bool SameSpot(WeatherForecast f) => Math.Abs(f.Lat - Lat) < 0.0001 && Math.Abs(f.Lon - Lon) < 0.0001;
}

/// <summary>The parsed MET Norway forecast, also the disk cache (weather-cache.json).</summary>
public sealed class WeatherForecast
{
    public double Lat { get; set; }
    public double Lon { get; set; }
    public DateTime FetchedUtc { get; set; }
    /// <summary>When MET says the data may change; no request before that.</summary>
    public DateTime ExpiresUtc { get; set; }
    /// <summary>Last-Modified header, sent back as If-Modified-Since.</summary>
    public string LastModified { get; set; } = "";
    public List<WeatherPoint> Points { get; set; } = [];
}

/// <summary>One forecast time step: hourly for about two days, then every six hours. Temperatures in °C, wind in m/s, rain in mm.</summary>
public sealed class WeatherPoint
{
    public DateTime Time { get; set; }
    public double Temp { get; set; }
    public double? Feels { get; set; }
    public double? Wind { get; set; }
    public string? Symbol1 { get; set; }
    public string? Symbol6 { get; set; }
    public double? Precip1 { get; set; }
    public double? Max6 { get; set; }
    public double? Min6 { get; set; }
}

public sealed record WeatherDay(string Name, string Symbol, string High, string Low, string Tip);

/// <summary>Everything the views show, formatted. Built from the forecast for one moment.</summary>
public sealed record WeatherView(string Symbol, string Temp, string Condition, string Detail, IReadOnlyList<WeatherDay> Days);

internal static class WeatherFormat
{
    const int DayCount = 4;

    /// <summary>Null when the forecast no longer covers <paramref name="nowUtc"/>.</summary>
    public static WeatherView? Build(WeatherForecast f, WeatherPlace place, WeatherUnits units, DateTime nowUtc)
    {
        WeatherPoint? cur = null;
        foreach (var p in f.Points)
        {
            if (p.Time > nowUtc) { cur ??= p; break; }
            cur = p;
        }
        if (cur is null || nowUtc - cur.Time > TimeSpan.FromHours(6)) return null;

        var symbol = cur.Symbol1 ?? cur.Symbol6 ?? "";
        var detail = new List<string>(3);
        if (cur.Feels is { } feels && Deg(feels, units) != Deg(cur.Temp, units)) detail.Add("Feels " + Deg(feels, units));
        if (cur.Wind is { } wind) detail.Add(Wind(wind, units));
        if (cur.Precip1 is double rain && rain > 0) detail.Add(Rain(rain, units));

        var tz = Zone(place.TimeZone);
        var today = TimeZoneInfo.ConvertTimeFromUtc(nowUtc, tz).Date;
        var days = new List<WeatherDay>(DayCount);
        for (var i = 0; i < DayCount; i++)
        {
            var date = today.AddDays(i);
            double hi = double.MinValue, lo = double.MaxValue;
            WeatherPoint? pick = null;
            var pickDistance = int.MaxValue;
            foreach (var p in f.Points)
            {
                if (p.Time < cur.Time) continue;
                var local = TimeZoneInfo.ConvertTimeFromUtc(p.Time, tz);
                if (local.Date != date) continue;
                hi = Math.Max(hi, Math.Max(p.Temp, p.Max6 ?? p.Temp));
                lo = Math.Min(lo, Math.Min(p.Temp, p.Min6 ?? p.Temp));
                // The day's symbol: the six hour period that starts closest to noon.
                if (p.Symbol6 is not null && Math.Abs(local.Hour - 12) < pickDistance) { pick = p; pickDistance = Math.Abs(local.Hour - 12); }
            }
            if (hi == double.MinValue) break;
            var daySymbol = pick?.Symbol6 ?? symbol;
            var name = i == 0 ? "Today" : date.ToString("ddd", UiCulture.Value);
            days.Add(new WeatherDay(name, daySymbol, Deg(hi, units), Deg(lo, units),
                $"{date.ToString("dddd d MMMM", UiCulture.Value)}: {Condition(daySymbol)}, {Deg(hi, units)} / {Deg(lo, units)}"));
        }

        return new WeatherView(symbol, Deg(cur.Temp, units), Condition(symbol), string.Join(" · ", detail), days);
    }

    public static string Deg(double celsius, WeatherUnits u)
    {
        var v = u == WeatherUnits.Imperial ? celsius * 9 / 5 + 32 : celsius;
        return $"{(int)Math.Round(v, MidpointRounding.AwayFromZero)}°";
    }

    static string Wind(double ms, WeatherUnits u) =>
        u == WeatherUnits.Imperial ? $"{Math.Round(ms * 2.23694):0} mph" : $"{Math.Round(ms):0} m/s";

    static string Rain(double mm, WeatherUnits u) =>
        u == WeatherUnits.Imperial ? (mm / 25.4).ToString("0.## in", UiCulture.Value) : mm.ToString("0.# mm", UiCulture.Value);

    static TimeZoneInfo Zone(string id) =>
        id.Length > 0 && TimeZoneInfo.TryFindSystemTimeZoneById(id, out var tz) ? tz : TimeZoneInfo.Local;

    public static string Ago(DateTime utc)
    {
        var age = DateTime.UtcNow - utc;
        return age.TotalMinutes < 1 ? "just now" : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago" : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago" : $"{(int)age.TotalDays} d ago";
    }

    /// <summary>"Light rain showers" for "lightrainshowers_day".</summary>
    public static string Condition(string symbol)
    {
        var i = symbol.IndexOf('_');
        return Names.TryGetValue(i < 0 ? symbol : symbol[..i], out var n) ? n : "";
    }

    /// <summary>English names from the MET Norway symbol legend (github.com/metno/weathericons, legend.csv).</summary>
    static readonly Dictionary<string, string> Names = new()
    {
        ["clearsky"] = "Clear sky", ["fair"] = "Fair", ["partlycloudy"] = "Partly cloudy", ["cloudy"] = "Cloudy", ["fog"] = "Fog",
        ["lightrainshowers"] = "Light rain showers", ["rainshowers"] = "Rain showers", ["heavyrainshowers"] = "Heavy rain showers",
        ["lightrainshowersandthunder"] = "Light rain showers and thunder", ["rainshowersandthunder"] = "Rain showers and thunder",
        ["heavyrainshowersandthunder"] = "Heavy rain showers and thunder",
        ["lightsleetshowers"] = "Light sleet showers", ["sleetshowers"] = "Sleet showers", ["heavysleetshowers"] = "Heavy sleet showers",
        ["lightsleetshowersandthunder"] = "Light sleet showers and thunder", ["sleetshowersandthunder"] = "Sleet showers and thunder",
        ["heavysleetshowersandthunder"] = "Heavy sleet showers and thunder",
        ["lightsnowshowers"] = "Light snow showers", ["snowshowers"] = "Snow showers", ["heavysnowshowers"] = "Heavy snow showers",
        ["lightsnowshowersandthunder"] = "Light snow showers and thunder", ["snowshowersandthunder"] = "Snow showers and thunder",
        ["heavysnowshowersandthunder"] = "Heavy snow showers and thunder",
        ["lightrain"] = "Light rain", ["rain"] = "Rain", ["heavyrain"] = "Heavy rain",
        ["lightrainandthunder"] = "Light rain and thunder", ["rainandthunder"] = "Rain and thunder", ["heavyrainandthunder"] = "Heavy rain and thunder",
        ["lightsleet"] = "Light sleet", ["sleet"] = "Sleet", ["heavysleet"] = "Heavy sleet",
        ["lightsleetandthunder"] = "Light sleet and thunder", ["sleetandthunder"] = "Sleet and thunder", ["heavysleetandthunder"] = "Heavy sleet and thunder",
        ["lightsnow"] = "Light snow", ["snow"] = "Snow", ["heavysnow"] = "Heavy snow",
        ["lightsnowandthunder"] = "Light snow and thunder", ["snowandthunder"] = "Snow and thunder", ["heavysnowandthunder"] = "Heavy snow and thunder",
    };

    /// <summary>A made up forecast for snapshot runs: nothing is fetched.</summary>
    public static (WeatherPlace, WeatherForecast) Demo()
    {
        var place = new WeatherPlace { Id = "1-72837", Name = "Oslo", Detail = "Norway", Lat = 59.9133, Lon = 10.7389, TimeZone = "Europe/Oslo", UrlPath = "Norway/Oslo/Oslo/Oslo" };
        var start = DateTime.UtcNow.Date.AddHours(DateTime.UtcNow.Hour);
        string[] days = ["partlycloudy_day", "lightrainshowers_day", "cloudy", "clearsky_day", "fair_day"];
        var f = new WeatherForecast { Lat = place.Lat, Lon = place.Lon, FetchedUtc = DateTime.UtcNow, ExpiresUtc = DateTime.UtcNow.AddHours(1) };
        for (var h = 0; h < 120; h++)
        {
            var t = start.AddHours(h);
            var temp = 9 + 5 * Math.Sin((t.Hour - 9) / 24.0 * 2 * Math.PI) + (h / 24) % 2;
            var sym = days[Math.Min(h / 24, days.Length - 1)];
            f.Points.Add(new WeatherPoint { Time = t, Temp = temp, Feels = temp - 2, Wind = 4, Symbol1 = sym, Symbol6 = sym, Precip1 = 0 });
        }
        return (place, f);
    }
}
