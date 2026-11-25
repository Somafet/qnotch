using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Calc.Windows;

/// <summary>The interface string catalog: every visible chrome string in each interface language.
/// Evaluator results, errors and calculation traces are produced by Calc.Core and are not part of it.</summary>
internal sealed partial class UiText
{
    internal sealed record Language(string Code, string Name);
    private sealed record Catalog(int Version, Language[] Languages, Dictionary<string, Dictionary<string, string>> Strings);
    private static readonly Lazy<UiText> english = new(() => new(Load(), "en"));
    private readonly Catalog catalog;
    internal string Code { get; }
    internal CultureInfo Culture { get; }
    internal static IReadOnlyList<Language> Languages => english.Value.catalog.Languages;
    internal static IReadOnlyCollection<string> Keys => english.Value.catalog.Strings.Keys;
    /// <summary>The active interface language. The window replaces it when the user selects another language.</summary>
    internal static UiText Current { get; set; } = english.Value;
    private UiText(Catalog catalog, string code) { this.catalog = catalog; Code = code; Culture = CultureInfo.GetCultureInfo(code); }
    internal static UiText For(string code) => Languages.Any(language => language.Code == code)
        ? new(english.Value.catalog, code) : throw new ArgumentException("Unsupported interface language");
    internal string this[string key] => catalog.Strings.TryGetValue(key, out var texts) ? texts[Code] : throw new KeyNotFoundException("Unknown interface string " + key);
    internal string Format(string key, params object[] arguments) => string.Format(Culture, this[key], arguments);
    /// <summary>The <paramref name="target"/> text for a string shown in this language, or null when it is not a fixed catalog string
    /// (formatted messages and evaluator or system text are left as they are).</summary>
    internal string? Retranslate(string shown, UiText target)
    {
        if (shown.Length == 0) return null;
        foreach (var texts in catalog.Strings.Values)
            if (texts[Code] == shown && !PlaceholderPattern().IsMatch(shown)) return texts[target.Code];
        return null;
    }

    /// <summary>An explicit choice wins; otherwise the first supported UI culture in the parent chain; otherwise English.</summary>
    internal static string Resolve(string? preference, CultureInfo system)
    {
        if (preference is not null && Languages.Any(language => language.Code == preference)) return preference;
        for (var culture = system; !string.IsNullOrEmpty(culture.Name); culture = culture.Parent)
        {
            if (Languages.FirstOrDefault(language => string.Equals(language.Code, culture.Name, StringComparison.OrdinalIgnoreCase)) is { } match) return match.Code;
            // zh-CN and zh-SG are Simplified Chinese; Traditional cultures have no catalog and fall back to English.
            if (culture.Name is "zh-CN" or "zh-SG") return "zh-Hans";
        }
        return "en";
    }

    private static Catalog Load()
    {
        using var stream = typeof(Calc.Documents.WorkspaceStore).Assembly.GetManifestResourceStream("Calc.UiStrings") ?? throw new InvalidDataException("Interface strings missing");
        var catalog = JsonSerializer.Deserialize<Catalog>(stream, new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? throw new InvalidDataException("Interface strings missing");
        Validate(catalog);
        return catalog;
    }
    /// <summary>A catalog is complete only if every key has a non-empty text in every language with the same placeholders.</summary>
    private static void Validate(Catalog catalog)
    {
        if (catalog.Version != 1 || catalog.Languages.Length == 0 || catalog.Languages[0].Code != "en") throw new InvalidDataException("Unsupported interface catalog");
        foreach (var (key, texts) in catalog.Strings)
        {
            var placeholders = Placeholders(texts.GetValueOrDefault("en") ?? "");
            foreach (var language in catalog.Languages)
                if (!texts.TryGetValue(language.Code, out var text) || string.IsNullOrWhiteSpace(text) || !Placeholders(text).SequenceEqual(placeholders))
                    throw new InvalidDataException($"Interface string {key} is incomplete for {language.Code}");
            if (texts.Count != catalog.Languages.Length) throw new InvalidDataException($"Interface string {key} has an unknown language");
        }
    }
    private static string[] Placeholders(string text) => PlaceholderPattern().Matches(text).Select(match => match.Value).Order(StringComparer.Ordinal).ToArray();
    [GeneratedRegex(@"\{\d+\}")]
    private static partial Regex PlaceholderPattern();
}
