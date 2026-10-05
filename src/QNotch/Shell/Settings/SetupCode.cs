using System.Buffers.Text;
using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Windows.Input;
using QNotch.Core;
using QNotch.Modules;
using QNotch.Shell.GameMode;

namespace QNotch.Shell.Settings;

/// <summary>
/// A setup code: the shared fields of the settings files as one line of text, "qnotch-setup-1:" and the base64url of deflated JSON
/// (settings id to fields). Only fields listed in a <see cref="SharedSettings"/> travel, and reading a code checks every value before
/// anything is written: unknown files and fields are dropped, numbers must be in range, and each file must still load as its type.
/// </summary>
public static class SetupCode
{
    const string Prefix = "qnotch-setup-1:";
    const int MaxCode = 16_384, MaxJson = 65_536, MaxString = 300, MaxItems = 200;

    public sealed record Section(string Id, string Title, SharedSettings Shared);

    /// <summary>Files to write (current settings with the code's values merged in), the titles of the sections it changes and the
    /// features it turns back on (they may record or listen, so the user sees them before applying).</summary>
    public sealed record Plan(IReadOnlyDictionary<string, string> Files, IReadOnlyList<string> Titles, IReadOnlyList<string> TurnsOn);

    /// <summary>Like <see cref="SettingsStore.Json"/>, but an enum must be one of its names: "Theme": 7 would load as an undefined value.</summary>
    static readonly JsonSerializerOptions Strict = StrictOptions();

    /// <summary>The shell's own shared settings. Left out on purpose: monitor, pin, profile name and picture, Start with Windows, last tab,
    /// and the Game mode app lists (they name the user's games).</summary>
    public static readonly IReadOnlyList<Section> ShellSections =
    [
        new("general", "Appearance and features", new(typeof(GeneralSettings), "HoverDwellMs:0..600", "LeaveDelayMs:100..1500",
            "AccentColor", "Theme", "ReduceMotion", "DisabledModules", "CardOrder", "CardVisible", "TabOrder")),
        new("hotkeys", "Hotkeys", new(typeof(ShortcutSettings), "Keys")),
        new("gamemode", "Game mode", new(typeof(GameModeSettings), "AutoDetect", "Opacity:0.3..1", "Height:16..40",
            "OffsetX:-1500..1500", "OffsetY:0..400", "Segments")),
    ];

    /// <summary>Shell sections, then every module that shares settings (on or off: its file is there either way).</summary>
    public static IReadOnlyList<Section> All(IEnumerable<ModuleInfo> modules) =>
        ShellSections.Concat(modules.Where(m => m.Shared is not null).Select(m => new Section(m.Id, m.Title, m.Shared!))).ToList();

    public static string Export(SettingsStore store, IEnumerable<Section> sections)
    {
        var root = new JsonObject();
        foreach (var s in sections)
        {
            var all = Serialize(store, s);
            var picked = new JsonObject();
            foreach (var (name, _) in s.Shared.Fields.Select(Field))
                if (all[name] is { } v) picked[name] = v.DeepClone();
            root[s.Id] = picked;
        }
        using var ms = new MemoryStream();
        using (var z = new DeflateStream(ms, CompressionLevel.SmallestSize)) z.Write(Encoding.UTF8.GetBytes(root.ToJsonString()));
        return Prefix + Base64Url.EncodeToString(ms.ToArray());
    }

    /// <summary>Checks a pasted code. Returns what to write, or null and a message for the user.</summary>
    public static Plan? Read(string code, SettingsStore store, IEnumerable<Section> sections, out string error)
    {
        error = "";
        code = code.Trim();
        if (!code.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase)) { error = "This is not a QNotch setup code."; return null; }
        if (code.Length > MaxCode) { error = "This code is too long."; return null; }

        JsonObject root;
        try
        {
            using var z = new DeflateStream(new MemoryStream(Base64Url.DecodeFromChars(code.AsSpan(Prefix.Length))), CompressionMode.Decompress);
            var buf = new byte[MaxJson + 1];
            int n = 0, read;
            while (n < buf.Length && (read = z.Read(buf, n, buf.Length - n)) > 0) n += read;
            if (n > MaxJson) { error = "This code is too long."; return null; }
            root = JsonNode.Parse(buf.AsSpan(0, n), documentOptions: new JsonDocumentOptions { AllowDuplicateProperties = false }) as JsonObject
                ?? throw new FormatException();
        }
        catch (Exception ex) when (ex is FormatException or InvalidDataException or JsonException)
        {
            error = "This code is damaged or incomplete. Copy it again.";
            return null;
        }

        var files = new Dictionary<string, string>();
        var titles = new List<string>();
        var turnsOn = new List<string>();
        foreach (var s in sections)
        {
            if (root[s.Id] is not JsonObject from) continue;
            var merged = Serialize(store, s);
            var changed = false;
            foreach (var (name, range) in s.Shared.Fields.Select(Field))
            {
                if (!from.TryGetPropertyValue(name, out var v) || v is null) continue;
                if (!Fits(v) || (range is var (min, max) && !(v is JsonValue jv && jv.TryGetValue(out double d) && d >= min && d <= max))
                    || (s.Id == "hotkeys" && name == "Keys" && !SafeGestures(v)))
                {
                    error = $"This code has a value QNotch cannot use ({s.Title}).";
                    return null;
                }
                merged[name] = v.DeepClone();
                changed = true;
            }
            if (!changed) continue;
            try { _ = JsonSerializer.Deserialize(merged, s.Shared.Type, Strict); }
            catch (JsonException)
            {
                error = $"This code has a value QNotch cannot use ({s.Title}).";
                return null;
            }
            files[s.Id] = merged.ToJsonString(SettingsStore.Json);
            titles.Add(s.Title);
            if (s.Id == "general") turnsOn.AddRange(TurnedOn(store, merged));
        }
        if (files.Count == 0) { error = "This code has no settings this version of QNotch knows."; return null; }
        return new Plan(files, titles, turnsOn);
    }

    /// <summary>Titles of the features that are off now and would be on after the code.</summary>
    static IEnumerable<string> TurnedOn(SettingsStore store, JsonObject merged)
    {
        var off = merged["DisabledModules"]?.AsArray().Select(n => n?.GetValue<string>()).ToHashSet(StringComparer.OrdinalIgnoreCase) ?? [];
        var now = store.Get<GeneralSettings>("general").DisabledModules;
        return ModuleList.All.Where(m => now.Contains(m.Id, StringComparer.OrdinalIgnoreCase) && !off.Contains(m.Id)).Select(m => m.Title);
    }

    /// <summary>Every gesture is empty (off) or parses and holds Alt or Win, so a code cannot take Ctrl+C or a plain key from other apps.</summary>
    static bool SafeGestures(JsonNode keys) => keys is JsonObject o && o.All(p =>
        p.Value is JsonValue v && v.TryGetValue(out string? g) && (g.Length == 0
            || (HotkeyService.TryParse(g, out var mods, out _) && (mods & (ModifierKeys.Alt | ModifierKeys.Windows)) != 0)));

    static JsonSerializerOptions StrictOptions()
    {
        var o = new JsonSerializerOptions(SettingsStore.Json);
        o.Converters.Clear();
        o.Converters.Add(new JsonStringEnumConverter(allowIntegerValues: false));
        return o;
    }

    static JsonObject Serialize(SettingsStore store, Section s) =>
        JsonSerializer.SerializeToNode(store.Get(s.Shared.Type, s.Id), s.Shared.Type, SettingsStore.Json)!.AsObject();

    /// <summary>"Opacity:0.3..1" becomes ("Opacity", (0.3, 1)).</summary>
    static (string Name, (double Min, double Max)? Range) Field(string spec)
    {
        var at = spec.IndexOf(':');
        if (at < 0) return (spec, null);
        var bounds = spec[(at + 1)..].Split("..");
        return (spec[..at], (double.Parse(bounds[0], CultureInfo.InvariantCulture), double.Parse(bounds[1], CultureInfo.InvariantCulture)));
    }

    /// <summary>No huge strings, lists or nesting: a hand-made code cannot bloat a settings file.</summary>
    static bool Fits(JsonNode node, int depth = 0) => depth < 4 && node switch
    {
        JsonArray a => a.Count <= MaxItems && a.All(i => i is not null && Fits(i, depth + 1)),
        JsonObject o => o.Count <= MaxItems && o.All(p => p.Key.Length <= MaxString && p.Value is not null && Fits(p.Value, depth + 1)),
        JsonValue v => v.GetValueKind() != JsonValueKind.String || v.GetValue<string>().Length <= MaxString,
        _ => false,
    };
}
