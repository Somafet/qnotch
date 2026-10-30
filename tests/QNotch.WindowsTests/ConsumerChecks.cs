using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using QNotch.Core.Consumers;
using QNotch.Modules.Agents;
using QNotch.Modules.Ai;

internal static class ConsumerChecks
{
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static JsonElement Element(string json) { using var doc = JsonDocument.Parse(json); return doc.RootElement.Clone(); }
    static void Error(Action run, string code)
    {
        try { run(); throw new Exception("Expected " + code); }
        catch (ConsumerException e) { Check(e.Code == code, e.Code); }
    }

    public static void Run() => RunAsync().GetAwaiter().GetResult();
    static async Task RunAsync()
    {
        ArgumentsAndLifecycle();
        QuotaFixtures();
        TranscriptFixtures();
        await Transport();
        await CliProcesses();
    }

    static void ArgumentsAndLifecycle()
    {
        var r = ConsumerCli.Parse("usage", ["--json", "--details", "--provider", "claude", "--account", "opaque"]);
        Check(r.Details && r.Provider == "claude" && r.Account == "opaque", "filters");
        foreach (var args in new[] { new[] { "--json", "--json" }, new[] { "--provider" }, new[] { "--refresh" }, new[] { "--provider", "foreign" } })
            Error(() => UsageCli.Validate(ConsumerCli.Parse("usage", args)), "invalid_arguments");
        Error(() => AgentsCli.Validate(ConsumerCli.Parse("agents", ["--account", "opaque"])), "invalid_arguments");
        Error(() => ConsumerProtocol.Validate(new(2, "usage")), "unsupported_version");
        var registry = new ConsumerRegistry();
        registry.Define("usage", "ai", true);
        registry.Define("agents", "agents", false);
        Check(registry.Capture(new(1, "usage")).ModuleStatus == "disabled", "disabled module");
        Check(registry.Capture(new(1, "agents")).ModuleStatus == "initializing", "initializing module");
        var calls = 0;
        registry.Register("agents", _ => { calls++; return new { value = 42 }; });
        Check(calls == 0, "no eager capture");
        registry.Complete("agents", true);
        Check(registry.Capture(new(1, "agents")).ModuleStatus == "ready" && calls == 1, "ready snapshot");
        registry.Complete("agents", false);
        Check(registry.Capture(new(1, "agents")).ModuleStatus == "unavailable" && calls == 1, "failed module not captured");
        var identity = new ConsumerIdentity(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray());
        var account = identity.Id("account", "C:\\private\\name");
        Check(account.Length == 32 && account == identity.Id("account", "C:\\private\\name") && account != identity.Id("session", "C:\\private\\name"), "opaque scoped IDs");
        Check(ConsumerProtocol.Text("a\u001bb\u202ec\n") == "abc", "control sanitization");
    }

    static void QuotaFixtures()
    {
        var now = new DateTime(2026, 10, 30, 12, 0, 0, DateTimeKind.Utc);
        var claude = ClaudeCodeProvider.ParseUsage(Element("""
            {"five_hour":{"utilization":42.5,"resets_at":"2026-10-30T16:00:00+02:00"},
             "seven_day_opus":{"utilization":8,"resets_at":null},"cedar_ember":{"eligible":true,"grants":[]}}
            """), "Max", now);
        var account = UsageProjection.Account("claude", "opaque", true, false, claude, null, now);
        Check(account.Windows[0] is { Id: "five_hour", DurationSeconds: 18000, UsedPercent: 42.5 } && account.Windows[0].ResetsAt == now.AddHours(2), "Claude window fields and UTC");
        Check(account.BankedResets is { Status: "none", Count: 0 } && account.ObservedAt == now, "known no credits");
        var missing = ClaudeCodeProvider.ParseUsage(Element("""{"five_hour":{"utilization":1}}"""), null, now);
        Check(missing.BankedStatus == "unknown", "missing credits unknown");
        var unsupported = ClaudeCodeProvider.ParseUsage(Element("""{"five_hour":{"utilization":1},"cedar_ember":{"eligible":false}}"""), null, now);
        Check(unsupported.BankedStatus == "unsupported", "explicit unsupported credits");
        Check(UsageProjection.Account("claude", "id", false, true, claude, null, now) is { Status: "disabled", Windows.Length: 0, ObservedAt: null, CheckedAt: null, Refreshing: false }, "disabled hides readings");
        Check(UsageProjection.Account("claude", "id", true, false, null, null, now) is { Status: "pending", Windows.Length: 0 }, "pending not zero");
        var expired = UsageResult.Ok([new("5-hour", 99, now.AddSeconds(-1), "five_hour", 18000)], "Max", now.AddHours(-5)) with { CheckedAt = now };
        Check(UsageProjection.Account("claude", "id", true, false, expired, null, now) is { Status: "unavailable", Error.Code: "expired_reading", ObservedAt: null }, "expired not reset to zero");
        var fail = UsageResult.Unavailable("Network unavailable.", "network_unavailable") with { CheckedAt = now };
        Check(UsageProjection.Account("claude", "id", true, false, fail, null, now) is { Status: "unavailable", Error.Code: "network_unavailable", Windows.Length: 0, Plan: null }, "failure no values");
        Check(CodexProvider.ParseCredits(Element("{}")) is { Status: "unknown", Banked: null }, "missing Codex credits");
        Check(CodexProvider.ParseCredits(Element("""{"credits":[],"availableCount":0}""")) is { Status: "none", Banked: null }, "explicit zero Codex credits");
        Check(CodexProvider.ParseCredits(Element("""{"credits":[{"status":"available"}],"availableCount":3}""")) is { Status: "available", Banked.Count: 3 }, "capped credit list");
        var dir = NewDir();
        try
        {
            var log = Path.Combine(dir, "rollout.jsonl");
            File.WriteAllText(log, """
                {"timestamp":"2026-10-30T10:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":31,"window_minutes":300,"resets_at":1793361600},"secondary":{"used_percent":17,"window_minutes":10080,"resets_in_seconds":604800},"plan_type":"plus"}}}

                """);
            var read = CodexProvider.ReadFile(log, now)!;
            Check(read is not null, "Codex fixture reading");
            // Secondary window stays valid regardless of the primary fixture's absolute reset time.
            var projected = UsageProjection.Account("codex", "opaque", true, false, read! with { CheckedAt = now }, null, now);
            Check(projected.ObservedAt == now.AddHours(-2) && projected.CheckedAt == now && projected.Source == "session_log", "check does not freshen observation");
            Check(projected.Windows.Any(w => w.Id == "secondary" && w.DurationSeconds == 604800), "Codex stable IDs");
            File.WriteAllText(log, """{"payload":{"rate_limits":{"primary":{"used_percent":1}}}}""" + "\n");
            Check(CodexProvider.ReadFile(log, now) is null, "missing timestamp not fabricated");
            var serialized = JsonSerializer.Serialize(account, ConsumerProtocol.Json);
            Check(!serialized.Contains("label\":null") && !serialized.Contains("C:\\"), "default details omitted");
        }
        finally { Directory.Delete(dir, true); }
    }

    static void TranscriptFixtures()
    {
        var dir = NewDir();
        try
        {
            var file = Path.Combine(dir, "session.jsonl");
            var subs = Path.Combine(dir, "session", "subagents");
            Directory.CreateDirectory(subs);
            const string ts = "2026-10-29T22:30:00Z";
            string Message(string id, int output, string model = "claude-sonnet-4") => JsonSerializer.Serialize(new
            {
                type = "assistant", timestamp = ts, message = new { id, model, usage = new { input_tokens = 100, cache_creation_input_tokens = 20, cache_read_input_tokens = 40, output_tokens = output } },
            });
            File.WriteAllText(file, Message("reply", 10) + "\n" + Message("reply", 30) + "\n");
            File.WriteAllText(Path.Combine(subs, "child.jsonl"), """{"type":"assistant","timestamp":"2026-10-29T22:30:00Z","message":{"id":"child","model":"unknown-model","usage":{"output_tokens":10}}}""" + "\n");
            var reader = new UsageReader();
            var days = reader.Read(file);
            var day = DateOnly.FromDateTime(DateTimeOffset.Parse(ts).LocalDateTime);
            Check(!reader.HadReadError && days[day].Tokens == 200 && days[day].Unpriced, "dedup plus subagents: 190 + 10 tokens");
            Check(reader.Read(file)[day].Tokens == 200 && reader.BytesRead == 0, "incremental no duplicate tokens");
            var state = new AgentsState();
            state.Sessions.Add(new("live") { Cwd = dir, Title = "secret title", Status = AgentStatus.NeedsYou, Since = DateTime.UtcNow });
            state.Usage["retained"] = new(dir, days) { ReadComplete = true, CheckedAt = DateTime.UtcNow };
            var identity = new ConsumerIdentity(new byte[32]);
            var snapshot = AgentsProjection.Capture(state, identity, false, "listening", "inactive");
            Check(snapshot.Sessions.Single().Status == "needs_you" && snapshot.Usage.Length == 2, "retained and live records");
            Check(snapshot.Usage.Single(u => u.Status == "ok").Total is { Tokens: 200, EstimatedUsd: null, PricingComplete: false }, "partial price not full estimate");
            Check(snapshot.Usage.Single(u => u.Status == "pending").Total is null, "unread usage not zero");
            var json = JsonSerializer.Serialize(snapshot, ConsumerProtocol.Json);
            Check(!json.Contains(dir.Replace("\\", "\\\\")) && !json.Contains("secret title") && !json.Contains("\"project\""), "private fields omitted");
            Check(AgentsProjection.Capture(state, identity, true, "listening", "inactive").Sessions.Single().Title == "secret title", "details opt in");
            File.Delete(file);
            reader.Read(file);
            Check(reader.HadReadError, "missing transcript unavailable");
            var known = AgentPrices.Cost("claude-sonnet-4", 100, 20, 0, 40, 30, false);
            Check(Math.Abs(known!.Value - 0.000837) < 1e-10, "fixture estimate: (300+75+12+450)/1M; not validation of list prices");
        }
        finally { Directory.Delete(dir, true); }
    }

    static async Task Transport()
    {
        var name = "QNotch.Consumer.test-" + Guid.NewGuid().ToString("N");
        var captures = 0;
        var host = new ConsumerHost((request, ct) =>
        {
            Interlocked.Increment(ref captures);
            return Task.FromResult(new ConsumerSnapshot("ready", request.Account == "large" ? new { value = new string('x', ConsumerProtocol.MaxResponse + 100) } : new { value = "fixture" }));
        }, name);
        try
        {
            var replies = await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => ConsumerCli.Exchange(new(1, "usage"), name)));
            Check(replies.All(r => Element(Encoding.UTF8.GetString(r)).GetProperty("data").GetProperty("value").GetString() == "fixture") && captures == 4, "concurrent bounded snapshots");
            async Task<string> Raw(string line)
            {
                using var ct = new CancellationTokenSource(5000);
                using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
                await client.ConnectAsync(ct.Token);
                await ConsumerProtocol.WriteLine(client, Encoding.UTF8.GetBytes(line), ct.Token);
                var response = await ConsumerProtocol.ReadLine(client, ConsumerProtocol.MaxResponse, ct.Token);
                return Element(Encoding.UTF8.GetString(response)).GetProperty("error").GetProperty("code").GetString()!;
            }
            Check(await Raw("{") == "invalid_arguments", "malformed JSON");
            Check(await Raw("""{"schema_version":2,"command":"usage"}""") == "unsupported_version", "protocol version");
            Check(await Raw(new string('x', ConsumerProtocol.MaxRequest + 1)) == "size_limit", "request size bound");
            var large = await ConsumerCli.Exchange(new(1, "usage", Account: "large"), name);
            Check(Element(Encoding.UTF8.GetString(large)).GetProperty("error").GetProperty("code").GetString() == "size_limit", "response size bound");
            Check(captures == 5, "invalid requests do not capture");
            using var stalled = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            await stalled.ConnectAsync(3000);
            CheckPipeAcl(stalled);
            using var readTimeout = new CancellationTokenSource(4000);
            var watch = Stopwatch.StartNew();
            Check(await stalled.ReadAsync(new byte[1], readTimeout.Token) == 0 && watch.ElapsedMilliseconds < 3500, "stalled client evicted");
            // A peer can disappear without leaving work behind.
            using (var gone = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous)) await gone.ConnectAsync(3000);
        }
        finally { host.Dispose(); await host.Completion.WaitAsync(TimeSpan.FromSeconds(4)); }
        Check(host.Completion.IsCompleted, "shutdown cancels listeners");
    }

    static void CheckPipeAcl(NamedPipeClientStream pipe)
    {
        var status = GetSecurityInfo(pipe.SafePipeHandle.DangerousGetHandle(), 6, 5, out _, out _, out _, out _, out var descriptor);
        Check(status == 0, "read pipe ACL");
        try
        {
            var bytes = new byte[GetSecurityDescriptorLength(descriptor)];
            Marshal.Copy(descriptor, bytes, 0, bytes.Length);
            var security = new RawSecurityDescriptor(bytes, 0);
            using var identity = WindowsIdentity.GetCurrent();
            Check(security.Owner == identity.User, "pipe owner is current token user, including elevated runners");
            Check(ConsumerPipeIdentity.HasOwner(pipe, identity.User!), "client accepts actual token user owner");
            Check(!ConsumerPipeIdentity.HasOwner(pipe, new SecurityIdentifier(WellKnownSidType.WorldSid, null)), "client rejects a different owner SID");
            Check(security.DiscretionaryAcl?.Count == 1 &&
                security.DiscretionaryAcl[0] is CommonAce ace && ace.SecurityIdentifier == identity.User && ace.AceQualifier == AceQualifier.AccessAllowed &&
                security.ControlFlags.HasFlag(ControlFlags.DiscretionaryAclProtected), "protected pipe ACL grants only current user");
        }
        finally { LocalFree(descriptor); }
    }

    [DllImport("advapi32.dll")] static extern uint GetSecurityInfo(nint handle, int type, uint information, out nint owner, out nint group, out nint dacl, out nint sacl, out nint descriptor);
    [DllImport("advapi32.dll")] static extern int GetSecurityDescriptorLength(nint descriptor);
    [DllImport("kernel32.dll")] static extern nint LocalFree(nint memory);

    static async Task CliProcesses()
    {
        var exe = Path.Combine(Path.GetDirectoryName(typeof(ConsumerCli).Assembly.Location)!, "QNotch.exe");
        Check(File.Exists(exe), "CLI apphost copied to test output");
        var instance = "consumer-process-" + Guid.NewGuid().ToString("N");
        async Task<(int Code, string Out, string Error)> Run(string[] args)
        {
            var start = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            start.Environment["QNOTCH_INSTANCE"] = instance;
            foreach (var arg in args) start.ArgumentList.Add(arg);
            using var process = Process.Start(start)!;
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(7));
            return (process.ExitCode, await stdout, await stderr);
        }
        var help = await Run(["usage", "--help"]);
        Check(help is { Code: 0, Error.Length: 0 } && help.Out.Contains("--account"), "help without service");
        var bad = await Run(["agents", "--provider", "claude", "--json"]);
        Check(bad.Code == 4 && bad.Out.Length == 0 && Element(bad.Error).GetProperty("error").GetProperty("code").GetString() == "invalid_arguments", "CLI argument stderr");
        var absent = await Run(["usage", "--json"]);
        Check(absent.Code == 3 && absent.Out.Length == 0 && Element(absent.Error).GetProperty("error").GetProperty("code").GetString() == "not_running", "no app and no GUI startup");
        // Hold the client inside a fixture server and inspect its actual loaded native/managed images.
        var observed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var host = new ConsumerHost(async (_, ct) =>
        {
            observed.TrySetResult();
            await release.Task.WaitAsync(ct);
            return new("ready", new { value = "árvíz" });
        }, "QNotch.Consumer." + instance);
        var startProbe = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        startProbe.Environment["QNOTCH_INSTANCE"] = instance;
        startProbe.ArgumentList.Add("usage"); startProbe.ArgumentList.Add("--json");
        using var probe = Process.Start(startProbe)!;
        try
        {
            await observed.Task.WaitAsync(TimeSpan.FromSeconds(4));
            var loaded = probe.Modules.Cast<ProcessModule>().Select(m => m.ModuleName).ToArray();
            Check(!loaded.Any(n => n.StartsWith("PresentationFramework", StringComparison.OrdinalIgnoreCase) || n.StartsWith("PresentationCore", StringComparison.OrdinalIgnoreCase)), "query did not load WPF");
            release.TrySetResult();
            var output = await probe.StandardOutput.ReadToEndAsync();
            var error = await probe.StandardError.ReadToEndAsync();
            await probe.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(4));
            Check(probe.ExitCode == 0 && error.Length == 0 && Element(output).GetProperty("data").GetProperty("value").GetString() == "árvíz", "UTF-8 CLI pipeline");
        }
        finally { release.TrySetResult(); if (!probe.HasExited) probe.Kill(true); }
    }

    static string NewDir() => Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "qnotch-consumer-tests-" + Guid.NewGuid().ToString("N"))).FullName;
}
