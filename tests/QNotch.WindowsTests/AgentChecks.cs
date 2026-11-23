using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Modules.Agents;

/// <summary>
/// Agent hook files and what they say, against temporary folders only: never ~/.claude, ~/.claude-* or ~/.codex. The Claude Code hooks use the exec
/// form, the shell form older builds wrote still counts as ours, and a connection is waiting until an event of its kind has arrived.
/// </summary>
static class AgentChecks
{
    const string Exe = @"C:\Apps\QNotch\QNotch.exe", Other = @"D:\Old Copy\QNotch.exe";
    const string Legacy = "\"C:/Apps/QNotch/QNotch.exe\" agent", LegacyOther = "\"D:/Old Copy/QNotch.exe\" agent";

    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "qnotch-agents-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            ExecForm(Dir(root, "exec"));
            LegacyForm(Dir(root, "legacy"));
            OtherCopies(Dir(root, "other"));
            UsersOwnHooks(Dir(root, "own"));
        }
        finally { Directory.Delete(root, true); }
        Texts();
        SeenState();
    }

    static string Dir(string root, string name) => Directory.CreateDirectory(Path.Combine(root, name)).FullName;

    static ClaudeHooks Hooks(string dir, string exe = Exe) => new(dir, "Default", exe);

    static JsonObject Read(string dir) => (JsonObject)JsonNode.Parse(File.ReadAllText(Path.Combine(dir, "settings.json")))!;

    static void Write(string dir, string json) => File.WriteAllText(Path.Combine(dir, "settings.json"), json);

    /// <summary>Every hook of ours in the file: (event, hook).</summary>
    static List<(string Event, JsonObject Hook, JsonObject Group)> Ours(JsonObject root) =>
        ((JsonObject)root["hooks"]!).SelectMany(e => ((JsonArray)e.Value!).OfType<JsonObject>().SelectMany(g => ((JsonArray)g["hooks"]!).OfType<JsonObject>().Select(h => (e.Key, h, g))))
            .Where(x => (x.h["command"]!.GetValue<string>() + " " + string.Join(' ', (x.h["args"] as JsonArray)?.Select(a => a!.GetValue<string>()) ?? [])).Contains("QNotch.exe", StringComparison.OrdinalIgnoreCase))
            .ToList();

    static string LegacyFile(string command) => $$"""
        { "hooks": {
            "SessionStart": [ { "hooks": [ { "type": "command", "command": {{JsonSerializer.Serialize(command)}}, "async": true } ] } ],
            "PreToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": {{JsonSerializer.Serialize(command)}}, "async": true } ] } ]
        } }
        """;

    /// <summary>All seven events, as a legacy connection of <paramref name="command"/> would have them.</summary>
    static string FullLegacyFile(string command, string? own = null)
    {
        var events = new[] { "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd" };
        var hooks = new JsonObject();
        foreach (var e in events)
        {
            var group = new JsonObject { ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = command, ["async"] = true }) };
            if (e is "PreToolUse" or "PostToolUse") group.Insert(0, "matcher", "*");
            hooks[e] = new JsonArray(group);
        }
        if (own is not null) ((JsonArray)hooks["Stop"]!).Add(new JsonObject { ["hooks"] = new JsonArray(JsonNode.Parse(own)) });
        return new JsonObject { ["theme"] = "dark", ["hooks"] = hooks }.ToJsonString();
    }

    static void ExecForm(string dir)
    {
        var h = Hooks(dir);
        h.Connect();
        var ours = Ours(Read(dir));
        Require(ours.Count == 7 && h.Check().Status == HookStatus.Connected);
        foreach (var (evt, hook, group) in ours)
        {
            // No shell: the command is the exe alone, with no quotes, and the verb is in args.
            Require(hook["command"]!.GetValue<string>() == "C:/Apps/QNotch/QNotch.exe");
            Require(hook["args"] is JsonArray { Count: 1 } args && args[0]!.GetValue<string>() == "agent");
            Require(hook["type"]!.GetValue<string>() == "command" && hook["async"]!.GetValue<bool>());
            Require((group["matcher"]?.GetValue<string>() == "*") == (evt is "PreToolUse" or "PostToolUse"));
        }
        // Connect again does not add a second set.
        h.Connect();
        Require(Ours(Read(dir)).Count == 7);
        h.Disconnect();
        Require(h.Check().Status == HookStatus.NotInstalled && Read(dir)["hooks"] is JsonObject { Count: 0 });
    }

    static void LegacyForm(string dir)
    {
        var h = Hooks(dir);
        Write(dir, FullLegacyFile(Legacy));
        // The shell form of this exe still reads as Connected, and is rewritten in place.
        Require(h.Check().Status == HookStatus.Connected);
        Require(h.Upgrade());
        var ours = Ours(Read(dir));
        Require(ours.Count == 7 && ours.All(o => o.Hook["args"] is JsonArray && o.Hook["command"]!.GetValue<string>() == "C:/Apps/QNotch/QNotch.exe"));
        Require(Read(dir)["theme"]!.GetValue<string>() == "dark" && h.Check().Status == HookStatus.Connected);
        Require(!h.Upgrade()); // nothing left to rewrite

        // Disconnect removes the shell form too.
        Write(dir, FullLegacyFile(Legacy));
        h.Disconnect();
        Require(h.Check().Status == HookStatus.NotInstalled && Ours(Read(dir)).Count == 0);

        // Connect replaces it: the same hooks once, in the exec form.
        Write(dir, FullLegacyFile(Legacy));
        h.Connect();
        Require(Ours(Read(dir)).Count == 7 && Ours(Read(dir)).All(o => o.Hook["args"] is JsonArray));

        // A file that is not connected (some events removed by hand) is not rewritten, and a missing file is not created.
        Write(dir, LegacyFile(Legacy));
        var before = File.ReadAllText(Path.Combine(dir, "settings.json"));
        Require(h.Check().Status == HookStatus.NotInstalled && !h.Upgrade() && File.ReadAllText(Path.Combine(dir, "settings.json")) == before);
        var empty = Hooks(Dir(Path.GetDirectoryName(dir)!, "missing"));
        Require(empty.Check().Status == HookStatus.NotInstalled && !empty.Upgrade() && !File.Exists(empty.FilePath));
    }

    static void OtherCopies(string dir)
    {
        var h = Hooks(dir);
        // Another copy, in either form: reported with its path, never rewritten, and "Use this copy" replaces it.
        foreach (var other in new[] { LegacyOther, null })
        {
            if (other is null) { Hooks(dir, Other).Connect(); } else Write(dir, FullLegacyFile(other));
            var (status, detail) = h.Check();
            Require(status == HookStatus.OtherCopy && detail.Replace('\\', '/') == "D:/Old Copy/QNotch.exe");
            Require(!h.Upgrade());
            h.Connect();
            Require(h.Check().Status == HookStatus.Connected && Ours(Read(dir)).Count == 7 && Ours(Read(dir)).All(o => o.Hook["command"]!.GetValue<string>() == "C:/Apps/QNotch/QNotch.exe"));
            Require(Hooks(dir, Other).Check().Status == HookStatus.OtherCopy);
        }
        // Another copy's hooks go on Disconnect, whichever form they are in.
        Hooks(dir, Other).Connect();
        h.Disconnect();
        Require(Ours(Read(dir)).Count == 0);
    }

    static void UsersOwnHooks(string dir)
    {
        // Their own hooks stay, also one in the exec form and one that mentions agent: only QNotch's entries go, and the rest of the file is kept.
        const string own = """{ "type": "command", "command": "node", "args": ["audit.js", "agent"] }""";
        Write(dir, FullLegacyFile(Legacy, own));
        var h = Hooks(dir);
        Require(h.Check().Status == HookStatus.Connected && h.Upgrade());
        Require(UserHooks(dir) == 1 && Ours(Read(dir)).Count == 7);
        h.Disconnect();
        Require(Ours(Read(dir)).Count == 0 && UserHooks(dir) == 1 && Read(dir)["theme"]!.GetValue<string>() == "dark");
        h.Connect();
        h.Disconnect();
        Require(UserHooks(dir) == 1);
    }

    static int UserHooks(string dir) => ((JsonObject)Read(dir)["hooks"]!).SelectMany(e => (JsonArray)e.Value!).OfType<JsonObject>()
        .SelectMany(g => (JsonArray)g["hooks"]!).Count(x => x!["command"]!.GetValue<string>() == "node");

    static void Texts()
    {
        // A connected hook file waits until an event of its kind arrives: warning color, then success.
        Require(AgentsStatus.Connected("claude", false) == ("Hooks added. Waiting for the first event: start a new Claude Code session.", "WarningBrush"));
        Require(AgentsStatus.Connected("codex", false) == ("Hooks added. Codex runs them once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app.", "WarningBrush"));
        Require(AgentsStatus.Connected("claude", true) == ("Connected. Receiving events.", "SuccessBrush") && AgentsStatus.Connected("codex", true) == AgentsStatus.Connected("claude", true));
        Require(AgentsStatus.Waiting(["claude", "codex"]) == "Hooks added. Waiting for the first event: start a new Claude Code session. Codex runs them once you trust them: /hooks in the CLI, or Settings, Hooks in the Codex app.");

        // The Agents tab's empty state: nothing connected, every connected kind waiting, an event has arrived.
        var none = AgentsStatus.Empty([]);
        Require(none.Title == "No agents running" && none.Detail.Contains("connect them in Settings, Agents"));
        var waiting = AgentsStatus.Empty([("claude", false)]);
        Require(waiting == ("Waiting for the first event", "Start a new Claude Code session."));
        var both = AgentsStatus.Empty([("claude", false), ("codex", false), ("claude", false)]);
        Require(both == ("Waiting for the first event", "Start a new Claude Code session. Trust the hooks in Codex: /hooks in the CLI, or Settings, Hooks in the Codex app."));
        Require(AgentsStatus.Empty([("codex", false)]).Detail == "Trust the hooks in Codex: /hooks in the CLI, or Settings, Hooks in the Codex app.");
        foreach (var seen in new[] { new[] { ("claude", true) }, new[] { ("claude", false), ("codex", true) } })
        {
            var idle = AgentsStatus.Empty(seen);
            Require(idle.Title == "No agents running" && idle.Detail.StartsWith("Sessions appear here when Claude Code or Codex is working.") && idle.Detail.Contains("T3 Code"));
        }

        // Analytics targets come from the fixed catalog.
        Require(AgentsStatus.Target("claude") == "agents_claude" && AgentsStatus.Target("codex") == "agents_codex" && AgentsStatus.Target("gemini") is null && AgentsStatus.Target(null) is null);
        Require(AnalyticsCatalog.Targets.Contains("agents_claude") && AnalyticsCatalog.Targets.Contains("agents_codex"));
    }

    static void SeenState()
    {
        var cfg = new AgentsConfig();
        Require(!cfg.Seen.Contains("claude") && !cfg.Seen.Contains("codex"));
        // Set when a hook arrives, cleared on Connect and Disconnect; a call that changes nothing reports it, so nothing is saved.
        Require(cfg.MarkSeen("claude", true) && !cfg.MarkSeen("claude", true));
        Require(cfg.Seen.Contains("claude") && !cfg.Seen.Contains("codex"));
        Require(cfg.MarkSeen("codex", true) && cfg.MarkSeen("claude", false) && !cfg.MarkSeen("claude", false));
        Require(!cfg.Seen.Contains("claude") && cfg.Seen.Contains("codex"));
        // It is saved with the module's settings, and a file from before it exists reads as nothing seen.
        var loaded = JsonSerializer.Deserialize<AgentsConfig>(JsonSerializer.Serialize(cfg, SettingsStore.Json), SettingsStore.Json)!;
        Require(loaded.Seen.SequenceEqual(["codex"]));
        Require(JsonSerializer.Deserialize<AgentsConfig>("""{"SoundDone":false}""", SettingsStore.Json)! is { Seen.Count: 0, SoundDone: false });
        // Local state: setup codes carry the sounds only.
        var shared = ModuleList.All.Single(m => m.Id == "agents").Shared!.Fields;
        Require(!shared.Contains("Seen") && shared.Contains("SoundDone"));
    }

    static void Require(bool condition) { if (!condition) throw new InvalidOperationException("assertion failed"); }
}
