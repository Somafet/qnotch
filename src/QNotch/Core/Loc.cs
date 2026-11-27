using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Windows.Markup;

namespace QNotch.Core;

/// <summary>
/// Interface language (spec/localization.md). The English text in the source is the key; each translation is one embedded
/// catalog, <c>Localization/&lt;code&gt;.json</c>, mapping that English text to the translated text. A missing or empty entry shows
/// the English text. The language is chosen once at startup (<see cref="Init"/>), so a change applies on restart.
/// Translate only what the user sees: never identifiers, saved values, analytics names, log lines or CLI output.
/// </summary>
public static class L
{
    public sealed record Language(string Code, string Name);

    /// <summary>The languages Settings offers, English first. A new language needs its catalog and a line here.</summary>
    public static readonly IReadOnlyList<Language> Languages = [new("en", "English"), new("it", "Italiano")];

    static Dictionary<string, string> _strings = new(StringComparer.Ordinal);

    /// <summary>The Windows display language, captured before <see cref="Init"/> replaces the UI culture.</summary>
    public static readonly CultureInfo SystemCulture = CultureInfo.CurrentUICulture;

    /// <summary>The active language code ("en" until <see cref="Init"/> runs).</summary>
    public static string Code { get; private set; } = "en";

    /// <summary>Culture for day and month names in the active language. Numbers keep the English format everywhere.</summary>
    public static CultureInfo Culture { get; private set; } = CultureInfo.GetCultureInfo("en-US");

    /// <summary>The translation of <paramref name="english"/>, or the English text when the catalog has none.</summary>
    public static string T(string english) => _strings.TryGetValue(english, out var t) && t.Length > 0 ? t : english;

    /// <summary><see cref="T"/> of a format string (<c>{0}</c> placeholders), then formatted.</summary>
    public static string F(string english, params object?[] args) => string.Format(CultureInfo.CurrentCulture, T(english), args);

    /// <summary>Marks a text for the catalog without translating it here: for tables whose entries are translated later with <c>L.T(entry)</c>.</summary>
    public static string N(string english) => english;

    /// <summary>An explicit choice wins; otherwise the first supported language in the system UI culture's chain; otherwise English.</summary>
    public static string Resolve(string? preference, CultureInfo system)
    {
        if (Languages.Any(l => l.Code == preference)) return preference!;
        for (var c = system; !string.IsNullOrEmpty(c.Name); c = c.Parent)
            if (Languages.FirstOrDefault(l => string.Equals(l.Code, c.Name, StringComparison.OrdinalIgnoreCase)) is { } match) return match.Code;
        return "en";
    }

    /// <summary>Selects the language before any UI text is built. Also sets the UI culture, which the Calculator follows when it has no language of its own.</summary>
    public static void Init(string? preference)
    {
        Code = Resolve(preference, SystemCulture);
        _strings = Code == "en" ? new(StringComparer.Ordinal) : Load(Code);
        Culture = CultureInfo.GetCultureInfo(Code == "en" ? "en-US" : Code);
        CultureInfo.DefaultThreadCurrentUICulture = Culture;
        CultureInfo.CurrentUICulture = Culture;
    }

    /// <summary>The saved choice in general.json ("" or missing: follow the system). Read directly: the settings store does not exist yet.</summary>
    public static string? SavedPreference()
    {
        try
        {
            var path = Path.Combine(Paths.DataDir, "general.json");
            if (!File.Exists(path)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            return doc.RootElement.TryGetProperty("Language", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        }
        catch { return null; }
    }

    internal static Dictionary<string, string> Load(string code)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("QNotch.Localization." + code + ".json");
        if (s is null) return new(StringComparer.Ordinal);
        var catalog = JsonSerializer.Deserialize<Catalog>(s, new JsonSerializerOptions { PropertyNameCaseInsensitive = true, ReadCommentHandling = JsonCommentHandling.Skip });
        return new(catalog?.Strings ?? [], StringComparer.Ordinal);
    }

    sealed record Catalog(string Code, string Name, Dictionary<string, string> Strings);
}

/// <summary>XAML text in the active language: <c>Text="{core:T 'Open settings'}"</c>.</summary>
[MarkupExtensionReturnType(typeof(string))]
public sealed class TExtension(string text) : MarkupExtension
{
    public string Text { get; set; } = text;
    public override object ProvideValue(IServiceProvider serviceProvider) => L.T(Text);
}
