using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using QNotch.Core;

namespace QNotch.Modules.Weather;

sealed class WeatherException(string message, bool offline, TimeSpan? retryAfter = null) : Exception(message)
{
    public bool Offline { get; } = offline;
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>
/// Forecast provider: yr.no's data from the MET Norway Locationforecast API, places from the yr.no location search.
/// All I/O runs on the thread pool; results reach <see cref="WeatherState"/> on the UI thread. One-shot timer re-armed after each
/// request, never before the Expires time MET sends (about 30 min), and requests carry If-Modified-Since, as MET's terms ask.
/// The last forecast is cached in weather-cache.json so the card shows at once and works offline.
/// </summary>
internal sealed class WeatherService
{
    static readonly string CacheFile = Path.Combine(Paths.DataDir, "weather-cache.json");
    static readonly JsonSerializerOptions CacheJson = new() { PropertyNameCaseInsensitive = true };
    static readonly TimeSpan Normal = TimeSpan.FromMinutes(30), MinWait = TimeSpan.FromMinutes(10), MaxWait = TimeSpan.FromHours(2),
        RetryAfterError = TimeSpan.FromMinutes(10);
    /// <summary>MET Norway requires a User-Agent that names the app and a way to reach its author.</summary>
    static readonly string UserAgent = $"QNotch/{typeof(WeatherService).Assembly.GetName().Version?.ToString(3)} (+https://github.com/Somafet/qnotch)";

    readonly ModuleContext _ctx;
    readonly WeatherState _s;
    readonly WeatherSettings _set;
    readonly Timer _timer;
    WeatherForecast? _data; // UI thread
    bool _busy;              // UI thread

    public WeatherService(ModuleContext ctx, WeatherState state, WeatherSettings settings)
    {
        _ctx = ctx;
        _s = state;
        _set = settings;
        _timer = new Timer(_ => _ctx.Bus.Run(Refresh), null, Timeout.Infinite, Timeout.Infinite);
    }

    public WeatherSettings Settings => _set;

    /// <summary>Loads the disk cache off the UI thread, shows it, then schedules the first request.</summary>
    public void Start()
    {
        if (_ctx.Settings.ReadOnly)
        {
            var (place, demo) = WeatherFormat.Demo();
            _set.Place ??= place;
            _data = demo;
            Show();
            return;
        }
        if (_set.Place is not { } p) { Show(); return; }
        Task.Run(() =>
        {
            var cache = ReadCache();
            _ctx.Bus.Run(() =>
            {
                if (cache is not null && _set.Place is { } now && now.SameSpot(cache)) _data = cache;
                Show();
                var wait = _data is null ? TimeSpan.FromSeconds(2) : Clamp(_data.ExpiresUtc - DateTime.UtcNow, TimeSpan.FromSeconds(2), MaxWait);
                _timer.Change(wait, Timeout.InfiniteTimeSpan);
            });
        });
    }

    /// <summary>Panel opened: "now" moved on since the last look, and a forecast past its expiry is fetched again.</summary>
    public void Wake()
    {
        if (_ctx.Settings.ReadOnly) return;
        Show();
        if (_data is { } d && DateTime.UtcNow > d.ExpiresUtc + TimeSpan.FromMinutes(1)) Refresh();
    }

    /// <summary>Settings changed (units, pill): re-format what is shown, no request.</summary>
    public void Reformat() => Show();

    /// <summary>A new place from Settings: drop the old forecast and fetch right away.</summary>
    public void SetPlace(WeatherPlace place)
    {
        QNotch.Core.Analytics.Track("weather", "select_place", "ui");
        _set.Place = place;
        _ctx.Settings.Save("weather", _set);
        _data = null;
        _s.Stale = false;
        _s.Message = "";
        Show();
        Refresh();
    }

    /// <summary>UI thread. The request, JSON parse and cache write run on the thread pool.</summary>
    public void Refresh()
    {
        if (_ctx.Settings.ReadOnly) return;
        if (_set.Place is not { } place) { Show(); return; }
        if (_busy) return;
        _busy = true;
        _s.Refreshing = true;
        if (_data is null) _s.Status = WeatherStatus.Loading;
        var prior = _data is { } d && place.SameSpot(d) ? d : null;
        Task.Run(async () =>
        {
            WeatherForecast? got = null;
            string error = "";
            var offline = false;
            TimeSpan next;
            try
            {
                got = await FetchAsync(place, prior);
                next = Clamp(got.ExpiresUtc - DateTime.UtcNow + TimeSpan.FromSeconds(30), MinWait, MaxWait);
                WriteCache(got);
            }
            catch (WeatherException ex) { error = ex.Message; offline = ex.Offline; next = ex.RetryAfter ?? RetryAfterError; }
            catch (Exception ex)
            {
                Log.Warn("Weather refresh failed", ex);
                error = "Something went wrong. See the log.";
                next = RetryAfterError;
            }
            _timer.Change(next, Timeout.InfiniteTimeSpan);
            _ctx.Bus.Run(() =>
            {
                _busy = false;
                _s.Refreshing = false;
                if (!ReferenceEquals(_set.Place, place)) { Refresh(); return; } // the place changed meanwhile
                if (got is not null) { _data = got; _s.Stale = false; _s.Message = ""; Show(); }
                else Fail(error, offline);
            });
        });
    }

    public void OpenYr()
    { QNotch.Core.Analytics.Track("weather", "open_forecast", "ui");
        if (_set.Place is not { } p) return;
        try { Process.Start(new ProcessStartInfo(p.YrUrl()) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn("Could not open yr.no", ex); }
    }

    // ---------- UI thread ----------

    /// <summary>Builds the view for this moment from the forecast in memory.</summary>
    void Show()
    {
        var place = _set.Place;
        _s.PlaceName = place?.Name ?? "";
        if (place is null)
        {
            _s.Status = WeatherStatus.NoPlace;
            _s.PillVisible = _s.GameVisible = false;
            return;
        }
        var view = _data is null ? null : WeatherFormat.Build(_data, place, _set.Units, DateTime.UtcNow);
        if (view is null)
        {
            if (_data is not null) { _s.Message = "The saved forecast is out of date."; _s.Status = WeatherStatus.Error; }
            else if (_s.Status != WeatherStatus.Error) _s.Status = WeatherStatus.Loading;
            _s.PillVisible = _s.GameVisible = false;
            return;
        }
        _s.Symbol = view.Symbol;
        _s.TempText = view.Temp;
        _s.ConditionText = view.Condition;
        _s.DetailText = view.Detail;
        if (!_s.Days.SequenceEqual(view.Days)) _s.Days = view.Days;
        _s.UpdatedText = (_s.Stale ? "Saved " : "Updated ") + WeatherFormat.Ago(_data!.FetchedUtc);
        _s.Status = WeatherStatus.Ready;
        _s.PillVisible = _set.ShowInPill;
        _s.GameVisible = true;
    }

    void Fail(string message, bool offline)
    {
        if (_data is not null)
        {
            _s.Stale = true;
            _s.Message = offline ? "Offline, showing the saved forecast." : $"Could not refresh: {message}";
            Show();
        }
        else
        {
            _s.Message = message;
            _s.Status = WeatherStatus.Error;
        }
    }

    static TimeSpan Clamp(TimeSpan t, TimeSpan min, TimeSpan max) => t < min ? min : t > max ? max : t;

    // ---------- thread pool ----------

    static HttpClient Http()
    {
        var http = new HttpClient(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", UserAgent);
        return http;
    }

    static async Task<WeatherForecast> FetchAsync(WeatherPlace place, WeatherForecast? prior)
    {
        // MET asks for at most four decimals, so nearby users share its cache.
        var url = FormattableString.Invariant($"https://api.met.no/weatherapi/locationforecast/2.0/complete?lat={Math.Round(place.Lat, 4)}&lon={Math.Round(place.Lon, 4)}")
            + (place.Elevation is { } e ? FormattableString.Invariant($"&altitude={e}") : "");
        using var http = Http();
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        if (prior is { LastModified.Length: > 0 }) req.Headers.TryAddWithoutValidation("If-Modified-Since", prior.LastModified);
        try
        {
            using var resp = await http.SendAsync(req);
            var expires = resp.Content.Headers.Expires?.UtcDateTime ?? DateTime.UtcNow + Normal;
            if (resp.StatusCode == HttpStatusCode.NotModified && prior is not null)
                return new WeatherForecast { Lat = prior.Lat, Lon = prior.Lon, FetchedUtc = DateTime.UtcNow, ExpiresUtc = expires, LastModified = prior.LastModified, Points = prior.Points };
            if (resp.StatusCode is HttpStatusCode.TooManyRequests or HttpStatusCode.Forbidden)
                throw new WeatherException("MET Norway asked QNotch to slow down. Trying again in an hour.", false, TimeSpan.FromHours(1));
            if (!resp.IsSuccessStatusCode) throw new WeatherException($"MET Norway returned {(int)resp.StatusCode}.", false);
            if (resp.StatusCode == HttpStatusCode.NonAuthoritativeInformation) Log.Warn("MET Norway says this Locationforecast version is deprecated");

            await using var body = await resp.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(body);
            var f = new WeatherForecast
            {
                Lat = place.Lat, Lon = place.Lon, FetchedUtc = DateTime.UtcNow, ExpiresUtc = expires,
                LastModified = resp.Content.Headers.LastModified?.ToString("R") ?? "",
            };
            foreach (var step in doc.RootElement.GetProperty("properties").GetProperty("timeseries").EnumerateArray())
            {
                var data = step.GetProperty("data");
                var now = data.GetProperty("instant").GetProperty("details");
                var p = new WeatherPoint
                {
                    Time = step.GetProperty("time").GetDateTime().ToUniversalTime(),
                    Temp = now.GetProperty("air_temperature").GetDouble(),
                    Feels = Num(now, "apparent_air_temperature"),
                    Wind = Num(now, "wind_speed"),
                };
                if (data.TryGetProperty("next_1_hours", out var h1))
                {
                    p.Symbol1 = Symbol(h1);
                    if (h1.TryGetProperty("details", out var d1)) p.Precip1 = Num(d1, "precipitation_amount");
                }
                if (data.TryGetProperty("next_6_hours", out var h6))
                {
                    p.Symbol6 = Symbol(h6);
                    if (h6.TryGetProperty("details", out var d6)) { p.Max6 = Num(d6, "air_temperature_max"); p.Min6 = Num(d6, "air_temperature_min"); }
                }
                f.Points.Add(p);
            }
            if (f.Points.Count == 0) throw new WeatherException("MET Norway sent an empty forecast.", false);
            return f;
        }
        catch (HttpRequestException) { throw new WeatherException("No connection to MET Norway.", true); }
        catch (TaskCanceledException) { throw new WeatherException("MET Norway did not respond in time.", true); }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            throw new WeatherException("MET Norway sent an unexpected response.", false);
        }
    }

    static double? Num(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

    static string? Symbol(JsonElement period) =>
        period.TryGetProperty("summary", out var s) && s.TryGetProperty("symbol_code", out var c) ? c.GetString() : null;

    /// <summary>The yr.no place search (what the search box on yr.no uses). Throws <see cref="WeatherException"/> with a user-facing message.</summary>
    public static async Task<IReadOnlyList<WeatherPlace>> SearchAsync(string query)
    {
        using var http = Http();
        try
        {
            using var resp = await http.GetAsync("https://www.yr.no/api/v0/locations/search?language=en&q=" + Uri.EscapeDataString(query));
            if (resp.StatusCode == HttpStatusCode.NotFound) return [];
            if (!resp.IsSuccessStatusCode) throw new WeatherException($"yr.no returned {(int)resp.StatusCode}.", false);
            await using var body = await resp.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(body);
            if (!doc.RootElement.TryGetProperty("_embedded", out var emb) || !emb.TryGetProperty("location", out var list)) return [];
            var found = new List<WeatherPlace>();
            foreach (var l in list.EnumerateArray().Take(8))
            {
                var name = Str(l, "name");
                var pos = l.GetProperty("position");
                var detail = new[] { Sub(l, "region"), Sub(l, "country") }.Where(s => s.Length > 0 && s != name).Distinct();
                found.Add(new WeatherPlace
                {
                    Id = Str(l, "id"), Name = name, Detail = string.Join(", ", detail),
                    Lat = pos.GetProperty("lat").GetDouble(), Lon = pos.GetProperty("lon").GetDouble(),
                    Elevation = l.TryGetProperty("elevation", out var el) && el.ValueKind == JsonValueKind.Number ? (int)Math.Round(el.GetDouble()) : null,
                    TimeZone = Str(l, "timeZone"), UrlPath = Str(l, "urlPath"),
                });
            }
            return found;
        }
        catch (HttpRequestException) { throw new WeatherException("No connection to yr.no.", true); }
        catch (TaskCanceledException) { throw new WeatherException("yr.no did not respond in time.", true); }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new WeatherException("yr.no sent an unexpected response.", false);
        }
    }

    static string Str(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    static string Sub(JsonElement e, string name) => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Object ? Str(v, "name") : "";

    static WeatherForecast? ReadCache()
    {
        try { return File.Exists(CacheFile) ? JsonSerializer.Deserialize<WeatherForecast>(File.ReadAllText(CacheFile), CacheJson) is { Points.Count: > 0 } f ? f : null : null; }
        catch (Exception ex) { Log.Warn("Weather cache unreadable", ex); return null; }
    }

    void WriteCache(WeatherForecast f)
    {
        if (_ctx.Settings.ReadOnly) return;
        try
        {
            var tmp = CacheFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(f, CacheJson));
            File.Move(tmp, CacheFile, true);
        }
        catch (Exception ex) { Log.Warn("Weather cache write failed", ex); }
    }
}
