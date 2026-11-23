using System.Text.Json;
using System.Text.Json.Nodes;

namespace QNotch.Modules.Agents;

internal enum HookStatus { NotInstalled, Connected, OtherCopy, Error }

/// <summary>
/// Adds and removes QNotch's hooks in an agent's hooks file. Ours are recognized by what they run (a QNotch exe followed by
/// <c>agent</c>, as a shell command or as Claude Code's exec form with <c>args</c>), so Disconnect removes exactly those and leaves the
/// user's own hooks alone. The file is backed up before every write.
/// </summary>
internal abstract class HookFile(string dir, string fileName)
{
    // Relaxed escaping keeps quotes and ampersands in a command readable for people who open the file.
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public string Dir => dir;
    public string FileName => fileName;
    public string FilePath => Path.Combine(dir, fileName);
    /// <summary>The row title in Settings, Agents.</summary>
    public abstract string Title { get; }
    /// <summary>"claude" or "codex": what the agent calls itself in a hook event, and the key of its "has an event arrived" state.</summary>
    public abstract string Kind { get; }
    /// <summary>Events the notch listens to.</summary>
    protected abstract string[] Events { get; }
    protected abstract string Command { get; }
    /// <summary>What a hook runs, as one line (<see cref="Line"/>): ours ends in <c>agent</c> and names a QNotch exe.</summary>
    protected abstract bool IsOurs(string? line);
    /// <summary>Whether one of our hooks points at this exe, whichever way it was written.</summary>
    protected virtual bool IsThisCopy(string line) => string.Equals(line, Command, StringComparison.OrdinalIgnoreCase);
    /// <summary>Our hook group for <paramref name="evt"/>.</summary>
    protected abstract JsonObject Group(string evt);

    /// <summary>Snapshot run: <see cref="Check"/> reports this instead of reading the file, and <see cref="ShownPath"/> starts at ~.</summary>
    public HookStatus? Demo { get; set; }

    /// <summary>The file's path for people; a demo hides the profile folder.</summary>
    public string ShownPath => Demo is null ? FilePath : Path.Join("~", Path.GetRelativePath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), FilePath));

    public (HookStatus Status, string Detail) Check()
    {
        if (Demo is { } demo) return (demo, "");
        try
        {
            var commands = AllHooks(Load()).Select(Line).Where(IsOurs).ToList();
            if (commands.Count == 0) return (HookStatus.NotInstalled, "");
            var other = commands.FirstOrDefault(c => !IsThisCopy(c!));
            // F:/x/QNotch.exe agent, "F:/x/QNotch.exe" agent, or & 'F:\x\QNotch.exe' agent codex: just the path.
            if (other is not null) return (HookStatus.OtherCopy, other[..other.LastIndexOf(" agent", StringComparison.Ordinal)].TrimStart('&', ' ').Trim('"', '\''));
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
        foreach (var evt in Events) (hooks[evt] as JsonArray ?? (JsonArray)(hooks[evt] = new JsonArray())).Add(Group(evt));
    });

    public void Disconnect() => Write(root => { if (Hooks(root) is { } hooks) RemoveOurs(hooks); });

    static JsonObject? Hooks(JsonObject root) => root["hooks"] as JsonObject;

    static IEnumerable<JsonNode?> AllHooks(JsonObject root) => Hooks(root)?.Select(e => e.Value).OfType<JsonArray>()
        .SelectMany(groups => groups.OfType<JsonObject>())
        .SelectMany(g => g["hooks"] as JsonArray ?? []) ?? [];

    /// <summary>One of our hooks is still a shell command: it has no <c>args</c>.</summary>
    protected bool HasShellForm() => AllHooks(Load()).Any(h => IsOurs(Line(h)) && h?["args"] is null);

    /// <summary>What a hook runs as one line: its command, and the <c>args</c> after it in the exec form.</summary>
    protected static string? Line(JsonNode? hook) =>
        hook?["command"]?.GetValue<string>() is { } command ? string.Join(' ', ((hook["args"] as JsonArray)?.Select(a => a?.GetValue<string>()) ?? []).Prepend(command)) : null;

    /// <summary>Drops our entries, then any group or event they leave empty.</summary>
    void RemoveOurs(JsonObject hooks)
    {
        foreach (var (evt, value) in hooks.ToList())
        {
            if (value is not JsonArray groups) continue;
            foreach (var g in groups.OfType<JsonObject>().ToList())
            {
                if (g["hooks"] is not JsonArray list) continue;
                foreach (var h in list.Where(h => IsOurs(Line(h))).ToList()) list.Remove(h);
                if (list.Count == 0) groups.Remove(g);
            }
            if (groups.Count == 0) hooks.Remove(evt);
        }
    }

    JsonObject Load()
    {
        if (!File.Exists(FilePath)) return new JsonObject();
        var text = File.ReadAllText(FilePath);
        return string.IsNullOrWhiteSpace(text) ? new JsonObject()
            : JsonNode.Parse(text, documentOptions: new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject
              ?? throw new InvalidDataException($"{fileName} is not a JSON object.");
    }

    /// <summary>Backup, edit, then write through a temp file so the agent never reads a half-written file.</summary>
    void Write(Action<JsonObject> edit)
    {
        var root = Load();
        Directory.CreateDirectory(dir);
        // Back up the file as it was before QNotch touched it, so Disconnect then Connect never overwrites the user's original.
        if (File.Exists(FilePath) && Check().Status == HookStatus.NotInstalled) File.Copy(FilePath, FilePath + ".qnotch-backup", overwrite: true);
        edit(root);
        var tmp = FilePath + ".qnotch-tmp";
        File.WriteAllText(tmp, root.ToJsonString(Indented));
        File.Move(tmp, FilePath, overwrite: true);
    }
}

/// <summary>QNotch's hooks in a Claude Code settings.json. <paramref name="exe"/> is this app's exe; only tests give another.</summary>
internal sealed class ClaudeHooks(string dir, string account, string? exe = null) : HookFile(dir, "settings.json")
{
    static readonly HashSet<string> ToolEvents = ["PreToolUse", "PostToolUse"];

    /// <summary>"Default" for ~/.claude, the folder suffix for ~/.claude-work and friends.</summary>
    public string Account => account;
    public override string Title => account == "Default" ? "Claude Code" : $"Claude Code ({account})";
    public override string Kind => "claude";
    protected override string[] Events => ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"];

    /// <summary>
    /// The exe, with forward slashes. Claude Code 2.1.139 and later start a hook with <c>args</c> directly, with no shell: Git for Windows
    /// is optional since 2.1.120, and without it a shell-form command runs in PowerShell, where <c>"C:/x/QNotch.exe" agent</c> is a parse error.
    /// </summary>
    protected override string Command => (exe ?? Core.AppPackage.CommandPath).Replace('\\', '/');

    protected override bool IsOurs(string? line) =>
        line is not null && line.TrimEnd().EndsWith(" agent", StringComparison.Ordinal) && line.Contains("qnotch", StringComparison.OrdinalIgnoreCase);

    /// <summary>The exe in the exec form (<c>C:/x/QNotch.exe agent</c>) or the shell form older builds wrote (<c>"C:/x/QNotch.exe" agent</c>).</summary>
    protected override bool IsThisCopy(string line) =>
        string.Equals(line[..line.LastIndexOf(" agent", StringComparison.Ordinal)].Trim('"').Replace('\\', '/'), Command, StringComparison.OrdinalIgnoreCase);

    // async: Claude Code does not wait for the hook, so a tool call is never slowed down by it. Tool events need a matcher.
    protected override JsonObject Group(string evt)
    {
        var group = new JsonObject { ["hooks"] = new JsonArray(new JsonObject { ["type"] = "command", ["command"] = Command, ["args"] = new JsonArray("agent"), ["async"] = true }) };
        if (ToolEvents.Contains(evt)) group.Insert(0, "matcher", "*");
        return group;
    }

    /// <summary>
    /// Rewrites shell-form hooks of this copy into the exec form, so a connection made by an older build keeps working without Git Bash.
    /// Only a file that is already connected to this exe; false when there was nothing to change.
    /// </summary>
    public bool Upgrade()
    {
        if (Check().Status != HookStatus.Connected || !HasShellForm()) return false;
        Connect();
        return true;
    }

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
                if (!string.Equals(d, Path.TrimEndingDirectorySeparator(main), StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(d, ".credentials.json")))
                    list.Add(new(d, Path.GetFileName(d)[".claude-".Length..]));
        }
        catch (Exception ex) { Core.Log.Warn("Looking for Claude Code folders failed", ex); }
        return list;
    }
}

/// <summary>
/// QNotch's hooks in Codex's user-level hooks.json: its own file, so config.toml is never rewritten. Codex skips a new or changed
/// hook until the user trusts it in Codex, and that stays their decision.
/// </summary>
internal sealed class CodexHooks(string dir) : HookFile(dir, "hooks.json")
{
    public override string Title => "Codex";
    public override string Kind => "codex";
    protected override string[] Events => ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"];

    /// <summary>
    /// Codex runs hooks through PowerShell on Windows: a quoted path needs the call operator. PowerShell does not wait for a GUI exe
    /// unless its output is piped; without the wait the shell exits at once and the hook cannot find the codex.exe above it.
    /// </summary>
    protected override string Command => $"& '{Core.AppPackage.CommandPath.Replace("'", "''")}' agent codex | Out-Null";

    protected override bool IsOurs(string? line) =>
        line is not null && line.Contains("' agent codex", StringComparison.Ordinal) && line.Contains("qnotch", StringComparison.OrdinalIgnoreCase);

    // async wherever Codex allows it: SessionEnd always runs in line, with a short timeout (1 s by default, at most 3).
    // The hook prints nothing, so it never answers a PermissionRequest in the user's place.
    protected override JsonObject Group(string evt) => new()
    {
        ["hooks"] = new JsonArray(evt == "SessionEnd"
            ? new JsonObject { ["type"] = "command", ["command"] = Command, ["timeout"] = 3 }
            : new JsonObject { ["type"] = "command", ["command"] = Command, ["async"] = true }),
    };

    /// <summary>CODEX_HOME or ~/.codex, when Codex is installed (or <paramref name="always"/>).</summary>
    public static CodexHooks? Find(bool always = false)
    {
        var dir = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(dir)) dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
        return always || Directory.Exists(dir) ? new(dir) : null;
    }
}
