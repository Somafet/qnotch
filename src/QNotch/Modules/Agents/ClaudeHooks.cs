using System.Text.Json;
using System.Text.Json.Nodes;

namespace QNotch.Modules.Agents;

internal enum HookStatus { NotInstalled, Connected, OtherCopy, Error }

/// <summary>
/// Adds and removes QNotch's hooks in a Claude Code settings.json. Ours are recognized by the command (a QNotch exe followed by
/// <c>agent</c>), so Disconnect removes exactly those and leaves the user's own hooks alone. The file is backed up before every write.
/// </summary>
internal sealed class ClaudeHooks(string dir, string account)
{
    /// <summary>Events the notch listens to. Tool events need a matcher; the others take none.</summary>
    static readonly string[] Events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"];
    static readonly HashSet<string> ToolEvents = ["PreToolUse", "PostToolUse"];
    // Relaxed escaping keeps the quotes around the exe path readable for people who open the file.
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public string Dir => dir;
    /// <summary>"Default" for ~/.claude, the folder suffix for ~/.claude-work and friends.</summary>
    public string Account => account;
    string File => Path.Combine(dir, "settings.json");

    /// <summary>Forward slashes and quotes: the same command works whether Claude Code runs hooks through Git Bash or cmd.</summary>
    static string Command => $"\"{Environment.ProcessPath!.Replace('\\', '/')}\" agent";

    /// <summary>The default config folder (or CLAUDE_CONFIG_DIR), plus every signed-in ~/.claude-* folder, like the AI usage card.</summary>
    public static List<ClaudeHooks> Discover()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var main = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (string.IsNullOrWhiteSpace(main)) main = Path.Combine(home, ".claude");
        var list = new List<ClaudeHooks> { new(main, "Default") };
        try
        {
            foreach (var d in Directory.GetDirectories(home, ".claude-*").Order())
                if (!string.Equals(d, Path.TrimEndingDirectorySeparator(main), StringComparison.OrdinalIgnoreCase) && System.IO.File.Exists(Path.Combine(d, ".credentials.json")))
                    list.Add(new(d, Path.GetFileName(d)[".claude-".Length..]));
        }
        catch (Exception ex) { Core.Log.Warn("Looking for Claude Code folders failed", ex); }
        return list;
    }

    static bool IsOurs(string? command) =>
        command is not null && command.TrimEnd().EndsWith(" agent", StringComparison.Ordinal) && command.Contains("qnotch", StringComparison.OrdinalIgnoreCase);

    public (HookStatus Status, string Detail) Check()
    {
        try
        {
            var commands = Hooks(Load())?.Select(e => e.Value).OfType<JsonArray>()
                .SelectMany(groups => groups.OfType<JsonObject>())
                .SelectMany(g => g["hooks"] as JsonArray ?? [])
                .Select(h => h?["command"]?.GetValue<string>())
                .Where(IsOurs).ToList() ?? [];
            if (commands.Count == 0) return (HookStatus.NotInstalled, "");
            var other = commands.FirstOrDefault(c => !string.Equals(c, Command, StringComparison.OrdinalIgnoreCase));
            if (other is not null) return (HookStatus.OtherCopy, other.Replace(" agent", "").Trim('"'));
            // Some events missing (removed by hand): Connect puts them back.
            return (commands.Count >= Events.Length ? HookStatus.Connected : HookStatus.NotInstalled, "");
        }
        catch (Exception ex) { return (HookStatus.Error, ex.Message); }
    }

    /// <summary>Replaces any QNotch hooks with ones that point at this exe.</summary>
    public void Connect() => Write(root =>
    {
        var hooks = Hooks(root) ?? (JsonObject)(root["hooks"] = new JsonObject());
        RemoveOurs(hooks);
        foreach (var evt in Events)
        {
            var groups = hooks[evt] as JsonArray ?? (JsonArray)(hooks[evt] = new JsonArray());
            // async: Claude Code does not wait for the hook, so a tool call is never slowed down by it.
            var group = new JsonObject { ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = Command, ["async"] = true }) };
            if (ToolEvents.Contains(evt)) group.Insert(0, "matcher", "*");
            groups.Add(group);
        }
    });

    public void Disconnect() => Write(root => { if (Hooks(root) is { } hooks) RemoveOurs(hooks); });

    static JsonObject? Hooks(JsonObject root) => root["hooks"] as JsonObject;

    /// <summary>Drops our entries, then any group or event they leave empty.</summary>
    static void RemoveOurs(JsonObject hooks)
    {
        foreach (var (evt, value) in hooks.ToList())
        {
            if (value is not JsonArray groups) continue;
            foreach (var g in groups.OfType<JsonObject>().ToList())
            {
                if (g["hooks"] is not JsonArray list) continue;
                foreach (var h in list.Where(h => IsOurs(h?["command"]?.GetValue<string>())).ToList()) list.Remove(h);
                if (list.Count == 0) groups.Remove(g);
            }
            if (groups.Count == 0) hooks.Remove(evt);
        }
    }

    JsonObject Load()
    {
        if (!System.IO.File.Exists(File)) return new JsonObject();
        var text = System.IO.File.ReadAllText(File);
        return string.IsNullOrWhiteSpace(text) ? new JsonObject()
            : JsonNode.Parse(text, documentOptions: new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject
              ?? throw new InvalidDataException("settings.json is not a JSON object.");
    }

    /// <summary>Backup, edit, then write through a temp file so Claude Code never reads a half-written settings.json.</summary>
    void Write(Action<JsonObject> edit)
    {
        var root = Load();
        Directory.CreateDirectory(dir);
        // Back up the file as it was before QNotch touched it, so Disconnect then Connect never overwrites the user's original.
        if (System.IO.File.Exists(File) && Check().Status == HookStatus.NotInstalled) System.IO.File.Copy(File, File + ".qnotch-backup", overwrite: true);
        edit(root);
        var tmp = File + ".qnotch-tmp";
        System.IO.File.WriteAllText(tmp, root.ToJsonString(Indented));
        System.IO.File.Move(tmp, File, overwrite: true);
    }
}
