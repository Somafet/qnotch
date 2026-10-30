using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace QNotch.Core;

/// <summary>Explicit, allowlisted product actions only. No automatic UI, content or exception collection.</summary>
internal sealed class Analytics : IDisposable
{
    internal static Analytics? Current { get; private set; }
    static readonly AsyncLocal<string?> ActionSurface = new();
    internal static IDisposable Surface(string surface) { var old = ActionSurface.Value; ActionSurface.Value = surface; return new SurfaceScope(() => ActionSurface.Value = old); }
    sealed class SurfaceScope(Action restore) : IDisposable { public void Dispose() => restore(); }
    readonly object _gate = new();
    readonly SemaphoreSlim _send = new(1);
    readonly Queue<AnalyticsEvent> _queue = new();
    readonly HttpClient _http;
    readonly Func<bool> _enabled;
    readonly Func<DateTimeOffset> _clock;
    readonly Func<(string Distinct, string Install, string Source)> _identity;
    readonly string _key;
    readonly Uri _endpoint;
    readonly Timer? _timer;
    (string Distinct, string Install, string Source)? _ids;
    AnalyticsEvent[] _failed = [];
    DateTimeOffset _firstFailure, _retryAt;
    int _failures;
    bool _disposed;
    CancellationTokenSource? _inflight;
    int _generation;
    int _sending;

    internal sealed record AnalyticsEvent(string uuid, string @event, string distinct_id, Dictionary<string, object> properties, string timestamp);

    internal Analytics(string key, Uri endpoint, Func<bool> enabled, Func<(string, string, string)> identity,
        HttpClient http, bool background = true, Func<DateTimeOffset>? clock = null)
    {
        _key = key; _endpoint = endpoint; _enabled = enabled; _identity = identity; _http = http;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        if (background) _timer = new Timer(_ => { _ = FlushAsync(); }, null, 10000, 10000);
    }

    internal static bool EnvironmentAllows => !string.Equals(Environment.GetEnvironmentVariable("QNOTCH_TELEMETRY_ENABLED"), "false", StringComparison.OrdinalIgnoreCase);

    internal static void Start(GeneralSettings settings, bool diagnostics)
    {
        // This gate must precede all identity reads, file creation, timers and HTTP construction.
        if (diagnostics) return;
        string key = "", host = "https://eu.i.posthog.com";
        try
        {
            using var stream = typeof(Analytics).Assembly.GetManifestResourceStream("QNotch.analytics-config.json");
            if (stream is not null)
            {
                using var config = JsonDocument.Parse(stream);
                key = config.RootElement.GetProperty("key").GetString() ?? "";
                host = config.RootElement.GetProperty("host").GetString() ?? host;
            }
        }
        catch { /* Missing configuration disables delivery. */ }
        key = Environment.GetEnvironmentVariable("QNOTCH_POSTHOG_KEY") ?? key;
        host = Environment.GetEnvironmentVariable("QNOTCH_POSTHOG_HOST") ?? host;
        if (!key.StartsWith("phc_", StringComparison.Ordinal) || !Uri.TryCreate(host, UriKind.Absolute, out var uri)
            || uri.Scheme != "https" || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment)) return;
        Current = new Analytics(key, new Uri(uri.AbsoluteUri.TrimEnd('/') + "/batch/"),
            () => settings.ShareUsageData && EnvironmentAllows,
            () => ReadIdentity(Paths.DataDir, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)),
            new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(10) });
    }

    internal static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    internal static (string Distinct, string Install, string Source) ReadIdentity(string data, string home)
    {
        var path = Path.Combine(data, "analytics-install-id");
        string install;
        try { install = File.ReadAllText(path).Trim(); if (!Guid.TryParse(install, out _)) throw new IOException(); }
        catch
        {
            install = Guid.NewGuid().ToString();
            Directory.CreateDirectory(data);
            var temp = path + "." + Guid.NewGuid().ToString("N");
            File.WriteAllText(temp, install);
            File.Move(temp, path, true);
        }
        var hash = Hash(install);
        foreach (var (file, source) in new[] { (Path.Combine(home, ".codex", "auth.json"), "codex"), (Path.Combine(home, ".claude.json"), "claude") })
        {
            try
            {
                using var json = JsonDocument.Parse(File.ReadAllText(file));
                var raw = source == "codex" ? json.RootElement.GetProperty("tokens").GetProperty("account_id").GetString() : json.RootElement.GetProperty("userID").GetString();
                if (!string.IsNullOrWhiteSpace(raw)) return (Hash(raw), hash, source);
            }
            catch { /* Missing/malformed providers fall through without logging personal data. */ }
        }
        return (hash, hash, "anonymous");
    }

    internal static void Track(string module, string action, string surface = "ui", string? target = null, bool? enabled = null) => Current?.Record(module, action, ActionSurface.Value ?? surface, target, enabled);
    internal void Record(string module, string action, string surface = "ui", string? target = null, bool? enabled = null)
    {
        lock (_gate)
        {
            if (_disposed || !_enabled()) { _queue.Clear(); _failed = []; return; }
            if (!AnalyticsCatalog.Allows(module, action) || surface is not ("ui" or "hotkey" or "cli" or "tray" or "onboarding")) return;
            target = target switch { "timer" => "pomodoro", "note" => "notes", "filetray" => "files", "colorpicker" => "color_picker", _ => target };
            if (target is not null && !AnalyticsCatalog.Targets.Contains(target)) return;
            try { _ids ??= _identity(); } catch { return; }
            var ids = _ids.Value;
            var properties = new Dictionary<string, object> {
                ["schema_version"] = 1, ["platform"] = "windows", ["app_version"] = typeof(Analytics).Assembly.GetName().Version?.ToString(3) ?? "0.0.0",
                ["module"] = module, ["action"] = action, ["surface"] = surface, ["outcome"] = "requested",
                ["install_id"] = ids.Install, ["identity_source"] = ids.Source, ["$process_person_profile"] = false };
            if (target is not null) properties["target"] = target;
            if (enabled is not null) properties["enabled"] = enabled.Value;
            while (_queue.Count + Math.Max(_failed.Length, _sending) >= 1000 && _queue.Count > 0) _queue.Dequeue();
            if (_queue.Count + Math.Max(_failed.Length, _sending) >= 1000) return;
            _queue.Enqueue(new(Guid.NewGuid().ToString(), "qnotch_action", ids.Distinct, properties, _clock().ToString("O")));
        }
    }

    internal void Clear() { lock (_gate) { _generation++; _queue.Clear(); _failed = []; _failures = 0; _retryAt = default; _inflight?.Cancel(); } }
    internal int Buffered { get { lock (_gate) return _queue.Count + Math.Max(_failed.Length, _sending); } }
    internal async Task FlushAsync(CancellationToken cancellation = default, bool force = false)
    {
        await _send.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            while (true)
            {
                AnalyticsEvent[] batch;
                int generation;
                CancellationTokenSource send;
                lock (_gate)
                {
                    if (!_enabled()) { Clear(); return; }
                    if (!force && _clock() < _retryAt) return;
                    if (_failed.Length > 0 && _clock() - _firstFailure >= TimeSpan.FromMinutes(30)) { _failed = []; _failures = 0; }
                    batch = _failed.Length > 0 ? _failed : Enumerable.Range(0, Math.Min(20, _queue.Count)).Select(_ => _queue.Dequeue()).ToArray();
                    if (batch.Length == 0) return;
                    _sending = batch.Length;
                    generation = _generation;
                    send = _inflight = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
                    send.CancelAfter(TimeSpan.FromSeconds(10));
                }
                try
                {
                    using var response = await _http.PostAsJsonAsync(_endpoint, new { api_key = _key, batch }, send.Token).ConfigureAwait(false);
                    if (response.IsSuccessStatusCode) { lock (_gate) { _failed = []; _failures = 0; } continue; }
                    var rejected = (int)response.StatusCode is 400 or 401 or 413;
                    Failed(batch, rejected, generation);
                    return;
                }
                catch { Failed(batch, false, generation); return; }
                finally { lock (_gate) { _sending = 0; if (ReferenceEquals(_inflight, send)) _inflight = null; } send.Dispose(); }
            }
        }
        finally { _send.Release(); }
    }

    void Failed(AnalyticsEvent[] batch, bool rejected, int generation)
    {
        lock (_gate)
        {
            if (!_enabled()) { Clear(); return; }
            if (generation != _generation) return;
            if (_failures++ == 0) _firstFailure = _clock();
            _failed = rejected ? [] : batch;
            var ceiling = Math.Min(300000, 2000 * Math.Pow(2, Math.Min(_failures - 1, 20)));
            _retryAt = _clock().AddMilliseconds(ceiling * (0.5 + Random.Shared.NextDouble() / 2));
        }
    }

    public void Dispose()
    {
        _timer?.Dispose();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try { FlushAsync(timeout.Token, true).GetAwaiter().GetResult(); } catch { }
        lock (_gate) { _disposed = true; Clear(); }
        if (ReferenceEquals(Current, this)) Current = null;
        _http.Dispose();
    }
}
