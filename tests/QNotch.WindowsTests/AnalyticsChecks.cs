using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using QNotch.Core;

internal static class AnalyticsChecks
{
    static void Check(bool value) { if (!value) throw new Exception("Analytics contract failed"); }
    sealed class Transport : HttpMessageHandler
    {
        internal readonly List<string> Bodies = [];
        internal HttpStatusCode Status = HttpStatusCode.OK;
        internal bool Block;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Check(request.RequestUri!.AbsolutePath == "/batch/");
            Bodies.Add(await request.Content!.ReadAsStringAsync(token));
            if (Block) await Task.Delay(Timeout.Infinite, token);
            return new HttpResponseMessage(Status);
        }
    }
    internal static void Run() => RunAsync().GetAwaiter().GetResult();
    internal static void Measure()
    {
        var transport = new Transport();
        using var analytics = new Analytics("phc_synthetic", new Uri("https://example.invalid/batch/"), () => true,
            () => (Analytics.Hash("synthetic-account"), Analytics.Hash("synthetic-install"), "codex"), new HttpClient(transport));
        analytics.Record("media", "play_pause");
        analytics.FlushAsync().GetAwaiter().GetResult();
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        Thread.Sleep(15000);
        process.Refresh();
        var cpu = process.TotalProcessorTime; var start = process.WorkingSet64;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        Thread.Sleep(30000);
        process.Refresh();
        Console.WriteLine(JsonSerializer.Serialize(new { workload = "configured analytics service only; synthetic identity and mocked HTTP; no WPF app/providers", warmup_seconds = 15, interval_seconds = clock.Elapsed.TotalSeconds,
            cpu_percent_one_core_ticks = (process.TotalProcessorTime - cpu).TotalSeconds / clock.Elapsed.TotalSeconds * 100,
            resident_bytes_start = start, resident_bytes_end = process.WorkingSet64, sends = transport.Bodies.Count, buffered = analytics.Buffered }));
    }
    static async Task RunAsync()
    {
        var now = DateTimeOffset.UtcNow;
        var enabled = false; var reads = 0;
        var transport = new Transport();
        using var analytics = new Analytics("phc_test", new Uri("https://example.invalid/batch/"), () => enabled,
            () => { reads++; return (Analytics.Hash("synthetic-account"), Analytics.Hash("synthetic-install"), "codex"); },
            new HttpClient(transport), false, () => now);
        Check(new GeneralSettings().ShareUsageData);
        analytics.Record("media", "play_pause");
        await analytics.FlushAsync();
        Check(reads == 0 && transport.Bodies.Count == 0);
        enabled = true;
        analytics.Record("clipboard", "personal clipboard content");
        analytics.Record("settings", "change", target: "personal setting text");
        Check(reads == 0 && analytics.Buffered == 0);
        analytics.Record("media", "play_pause");
        transport.Status = HttpStatusCode.ServiceUnavailable;
        await analytics.FlushAsync();
        Check(reads == 1 && analytics.Buffered == 1);
        var first = transport.Bodies.Single();
        now = now.AddMinutes(6);
        transport.Status = HttpStatusCode.OK;
        await analytics.FlushAsync();
        Check(first == transport.Bodies[1]); // UUID, timestamp and identity remain identical across retries.
        using (var payload = JsonDocument.Parse(first))
        {
            var ev = payload.RootElement.GetProperty("batch")[0];
            var props = ev.GetProperty("properties");
            Check(ev.GetProperty("event").GetString() == "qnotch_action");
            Check(!props.GetProperty("$process_person_profile").GetBoolean());
            Check(props.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] {
                "$process_person_profile", "action", "app_version", "identity_source", "install_id", "module", "outcome", "platform", "schema_version", "surface" }.Order()));
            Check(!first.Contains("synthetic-account") && !first.Contains("synthetic-install"));
        }
        for (var i = 0; i < 1100; i++) analytics.Record("media", "next");
        Check(analytics.Buffered == 1000);
        await analytics.FlushAsync();
        Check(analytics.Buffered == 0);
        Check(transport.Bodies.Skip(2).All(b => JsonDocument.Parse(b).RootElement.GetProperty("batch").GetArrayLength() <= 20));
        analytics.Record("media", "next");
        enabled = false;
        var sent = transport.Bodies.Count;
        await analytics.FlushAsync();
        Check(analytics.Buffered == 0 && transport.Bodies.Count == sent);
        enabled = true;
        analytics.Record("media", "next");
        transport.Status = HttpStatusCode.ServiceUnavailable;
        await analytics.FlushAsync();
        now = now.AddMinutes(31);
        analytics.Record("media", "previous");
        transport.Status = HttpStatusCode.OK;
        await analytics.FlushAsync();
        Check(analytics.Buffered == 0);
        Check(!transport.Bodies.Last().Contains("\"action\":\"next\""));
        analytics.Record("media", "next");
        transport.Status = HttpStatusCode.Unauthorized;
        await analytics.FlushAsync();
        Check(analytics.Buffered == 0); // Permanent batch rejection is never retried.
        now = now.AddMinutes(6);
        analytics.Record("settings", "change_feature", target: "media", enabled: false);
        transport.Status = HttpStatusCode.OK;
        await analytics.FlushAsync();
        using (var target = JsonDocument.Parse(transport.Bodies.Last()))
        {
            var props = target.RootElement.GetProperty("batch")[0].GetProperty("properties");
            Check(props.GetProperty("target").GetString() == "media" && !props.GetProperty("enabled").GetBoolean());
        }
        analytics.Record("media", "next");
        transport.Block = true;
        var sending = analytics.FlushAsync();
        enabled = false;
        analytics.Clear();
        await sending;
        enabled = true;
        transport.Block = false;
        Check(analytics.Buffered == 0); // Consent generation cannot resurrect an in-flight batch.

        var root = Path.Combine(Path.GetTempPath(), "qnotch-analytics-" + Guid.NewGuid());
        Directory.CreateDirectory(Path.Combine(root, "home", ".codex"));
        try
        {
            var home = Path.Combine(root, "home"); var data = Path.Combine(root, "data");
            var anonymous = Analytics.ReadIdentity(data, home);
            Check(anonymous == Analytics.ReadIdentity(data, home));
            File.WriteAllText(Path.Combine(home, ".claude.json"), "{\"userID\":\"synthetic-claude\"}");
            var claude = Analytics.ReadIdentity(data, home);
            Check(claude.Distinct == Analytics.Hash("synthetic-claude") && claude.Install == anonymous.Install);
            File.WriteAllText(Path.Combine(home, ".codex", "auth.json"), "{\"tokens\":{\"account_id\":\"synthetic-codex\"}}");
            Check(Analytics.ReadIdentity(data, home).Distinct == Analytics.Hash("synthetic-codex"));
            File.WriteAllText(Path.Combine(home, ".codex", "auth.json"), "{bad json");
            Check(Analytics.ReadIdentity(data, home) == claude);
        }
        finally { Directory.Delete(root, true); }
        var env = Environment.GetEnvironmentVariable("QNOTCH_TELEMETRY_ENABLED");
        try { Environment.SetEnvironmentVariable("QNOTCH_TELEMETRY_ENABLED", "false"); Check(!Analytics.EnvironmentAllows); }
        finally { Environment.SetEnvironmentVariable("QNOTCH_TELEMETRY_ENABLED", env); }
        Analytics.Start(new GeneralSettings(), true);
        Check(Analytics.Current is null); // Diagnostics never initialize transport or identity.

        var fixtures = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../fixtures/analytics"));
        using var catalog = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "catalog-v1.json")));
        foreach (var module in catalog.RootElement.GetProperty("modules").EnumerateObject())
            foreach (var action in module.Value.EnumerateArray()) Check(AnalyticsCatalog.Allows(module.Name, action.GetString()!));
        using var vectors = JsonDocument.Parse(File.ReadAllText(Path.Combine(fixtures, "identity-v1.json")));
        foreach (var vector in vectors.RootElement.GetProperty("vectors").EnumerateArray())
            Check(Analytics.Hash(vector.GetProperty("raw").GetString()!) == vector.GetProperty("sha256").GetString());
    }
}
