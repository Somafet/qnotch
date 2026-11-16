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
        var targets = catalog.RootElement.GetProperty("targets").EnumerateArray().Select(t => t.GetString()!).ToHashSet();
        Check(targets.SetEquals(AnalyticsCatalog.Targets));
        var lifecycle = catalog.RootElement.GetProperty("lifecycle");
        Check(lifecycle.GetProperty("event").GetString() == "qnotch_active");
        Check(new[] { "launch", "day" }.SequenceEqual(lifecycle.GetProperty("reasons").EnumerateArray().Select(r => r.GetString())));
        Check(new[] { "clean", "unclean", "none" }.SequenceEqual(lifecycle.GetProperty("previous_exit").EnumerateArray().Select(r => r.GetString())));

        // Channels: fixed values only, and every Windows value is reachable.
        var channels = new[] {
            Analytics.Channel(true, true, true, @"C:\Program Files\WindowsApps\Somafet.QNotch_0.9.2.0_x64__x\QNotch.exe"),
            Analytics.Channel(false, true, true, @"C:\Users\x\AppData\Local\Microsoft\WinGet\Packages\Somafet.QNotch_Microsoft.Winget.Source_8wekyb3d8bbwe\QNotch.exe"),
            Analytics.Channel(false, true, true, @"C:\Users\x\scoop\apps\qnotch\current\QNotch.exe"),
            Analytics.Channel(false, true, true, @"C:\ProgramData\chocolatey\lib\qnotch\tools\QNotch.exe"),
            Analytics.Channel(false, true, true, @"D:\Tools\QNotch\QNotch.exe"),
            Analytics.Channel(false, true, false, @"C:\Users\x\Downloads\QNotch.exe"),
            Analytics.Channel(false, false, true, @"C:\ProgramData\chocolatey\lib\qnotch\tools\QNotch.exe") };
        Check(channels.SequenceEqual(lifecycle.GetProperty("channels").GetProperty("windows").EnumerateArray().Select(c => c.GetString())));
        Check(Analytics.Channel(false, true, false, null) == "exe");

        // Continuous controls: one action per gesture, a new one after a pause of at least Gestures.Gap.
        Check(Analytics.Gestures.Starts("test/slider", 10_000) && !Analytics.Gestures.Starts("test/slider", 11_000)
            && !Analytics.Gestures.Starts("test/slider", 12_400) && Analytics.Gestures.Starts("test/slider", 13_900)
            && Analytics.Gestures.Starts("test/other", 13_900));

        // Agent hooks: one cli_hook per session.
        var agents = new QNotch.Modules.Agents.AgentsModule();
        Check(agents.FirstHook("session-a") && !agents.FirstHook("session-a") && agents.FirstHook("session-b"));

        await LifecycleAsync();
    }

    static async Task LifecycleAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "qnotch-analytics-life-" + Guid.NewGuid());
        var state = Path.Combine(root, "analytics-run-state");
        var now = new DateTimeOffset(2026, 11, 16, 23, 59, 0, TimeSpan.Zero);
        var enabled = true;
        Analytics Create(Transport transport) => new("phc_test", new Uri("https://example.invalid/batch/"), () => enabled,
            () => (Analytics.Hash("synthetic-account"), Analytics.Hash("synthetic-install"), "anonymous"), new HttpClient(transport), false, () => now);
        static JsonElement[] Events(Transport transport) => transport.Bodies.SelectMany(b => JsonDocument.Parse(b).RootElement.GetProperty("batch").EnumerateArray()).ToArray();
        try
        {
            var first = new Transport();
            using (var life = Create(first))
            {
                life.Heartbeat();
                Check(life.Buffered == 0); // no day event before the launch
                life.Launched(["timer", "stats", "note", "not-a-module", "stats"], "zip", state);
                Check(File.ReadAllText(state) == "running");
                life.Heartbeat();
                Check(life.Buffered == 1); // same UTC day as the launch
                now = now.AddMinutes(2);
                life.Heartbeat(); life.Heartbeat();
                Check(life.Buffered == 2); // one day event per new UTC day
                await life.FlushAsync();
            }
            Check(File.ReadAllText(state) == "exited");
            var events = Events(first);
            Check(events.Length == 2 && events.All(e => e.GetProperty("event").GetString() == "qnotch_active"));
            var launch = events[0].GetProperty("properties");
            Check(launch.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] {
                "$process_person_profile", "app_version", "channel", "identity_source", "install_id", "modules", "platform", "previous_exit", "reason", "schema_version" }.Order()));
            Check(launch.GetProperty("reason").GetString() == "launch" && launch.GetProperty("previous_exit").GetString() == "none" && launch.GetProperty("channel").GetString() == "zip");
            Check(launch.GetProperty("modules").EnumerateArray().Select(m => m.GetString()).SequenceEqual(new[] { "notes", "pomodoro", "stats" }));
            Check(!launch.GetProperty("$process_person_profile").GetBoolean());
            var day = events[1].GetProperty("properties");
            Check(day.GetProperty("reason").GetString() == "day" && !day.TryGetProperty("previous_exit", out _));

            string PreviousExit()
            {
                var transport = new Transport();
                using (var life = Create(transport)) { life.Launched(["stats"], "exe", state); life.FlushAsync().GetAwaiter().GetResult(); }
                return Events(transport).Single().GetProperty("properties").GetProperty("previous_exit").GetString()!;
            }
            Check(PreviousExit() == "clean");
            File.WriteAllText(state, "running"); // the last run never reached its exit
            Check(PreviousExit() == "unclean");

            enabled = false;
            File.Delete(state);
            var off = new Transport();
            using (var life = Create(off)) { life.Launched(["stats"], "exe", state); life.Heartbeat(); Check(life.Buffered == 0); }
            Check(!File.Exists(state) && off.Bodies.Count == 0); // opted out: no marker, nothing sent
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }
}
