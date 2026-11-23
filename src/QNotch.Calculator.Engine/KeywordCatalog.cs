using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Calc.Core;

internal enum KeywordRole { Of, Sum, Average, Double, Half, To, Nearest, Decimals, Significant, LeadingDecimals, LeadingSignificant, Digits, RoundEnd, PostfixDouble, PostfixHalf }

/// <summary>Bounded embedded syntax data. Keywords are matched only in their grammatical role; source names are never rewritten.</summary>
internal static class KeywordCatalog
{
    private sealed record Alias(string[] Words);
    private static readonly Dictionary<KeywordRole, Dictionary<string, Alias[]>> aliases;
    private static readonly Dictionary<char, string[]> cjkLexemes;
    static KeywordCatalog()
    {
        using var stream = typeof(KeywordCatalog).Assembly.GetManifestResourceStream("Calc.LanguageKeywords")!;
        using var document = JsonDocument.Parse(stream);
        var roles = new Dictionary<KeywordRole, HashSet<string>>(); var unspaced = new HashSet<string>(StringComparer.Ordinal);
        var languages = document.RootElement.GetProperty("languages");
        if (languages.GetArrayLength() != 9) throw new InvalidDataException("Expected nine syntax languages");
        foreach (var language in languages.EnumerateArray())
            foreach (var role in language.GetProperty("keywords").EnumerateObject())
            {
                var key = Enum.Parse<KeywordRole>(role.Name);
                if (!roles.TryGetValue(key, out var values)) roles[key] = values = new(StringComparer.Ordinal);
                foreach (var item in role.Value.EnumerateArray())
                {
                    var text = Normalize(item.GetString()!);
                    if (text.Length is 0 or > 64 || text.Split(' ').Length > 8) throw new InvalidDataException("Invalid keyword alias");
                    values.Add(text);
                    if (language.GetProperty("unspaced").GetBoolean())
                        foreach (var word in text.Split(' ')) if (word.Any(c => c > 127)) unspaced.Add(word);
                }
            }
        if (roles.Values.Sum(values => values.Count) > 256) throw new InvalidDataException("Keyword catalog limit exceeded");
        aliases = roles.ToDictionary(pair => pair.Key, pair => pair.Value.OrderByDescending(text => text.Split(' ').Length)
            .ThenByDescending(text => text.Length).Select(text => new Alias(text.Split(' '))).GroupBy(alias => alias.Words[0])
            .ToDictionary(group => group.Key, group => group.ToArray(), StringComparer.Ordinal));
        cjkLexemes = unspaced.GroupBy(text => text[0]).ToDictionary(group => group.Key, group => group.OrderByDescending(text => text.Length).ToArray());
    }
    private static string Normalize(string text) => text.Normalize(NormalizationForm.FormC).ToUpperInvariant();
    internal static int Match(IReadOnlyList<Token> tokens, int position, KeywordRole role)
    {
        if (position >= tokens.Count || tokens[position].Kind != TokenKind.Name || !aliases.TryGetValue(role, out var words) ||
            !words.TryGetValue(Normalize(tokens[position].Text), out var candidates)) return 0;
        foreach (var alias in candidates)
        {
            if (position + alias.Words.Length > tokens.Count) continue;
            var found = true;
            for (var index = 0; index < alias.Words.Length; index++)
                if (Normalize(tokens[position + index].Text) != alias.Words[index]) { found = false; break; }
            if (found) return alias.Words.Length;
        }
        return 0;
    }
    internal static bool IsOf(string text) => aliases[KeywordRole.Of].ContainsKey(Normalize(text));
    internal static bool IsMark(char value) => char.GetUnicodeCategory(value) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark;
    internal static int CjkTokenLength(string source, int start, HashSet<string>? knownNames)
    {
        if (!cjkLexemes.TryGetValue(source[start], out var candidates)) return 0;
        // Bound lookahead, and protect complete declared identifiers and all call names.
        var identifierEnd = start;
        while (identifierEnd < source.Length && identifierEnd - start <= 128 &&
            (char.IsLetterOrDigit(source[identifierEnd]) || source[identifierEnd] == '_' || IsMark(source[identifierEnd]))) identifierEnd++;
        if (identifierEnd - start <= 128)
        {
            if (knownNames?.Contains(source[start..identifierEnd]) == true) return 0;
            var afterName = identifierEnd;
            while (afterName < source.Length && char.IsWhiteSpace(source[afterName])) afterName++;
            if (afterName < source.Length && source[afterName] == '(') return 0;
        }
        foreach (var candidate in candidates)
        {
            if (!source.AsSpan(start).StartsWith(candidate, StringComparison.Ordinal)) continue;
            var end = start + candidate.Length;
            if (end == source.Length || !char.IsLetter(source[end]) || cjkLexemes.ContainsKey(source[end]) || KnownOperandFollows(end)) return candidate.Length;
        }
        return 0;
        bool KnownOperandFollows(int position)
        {
            if (knownNames is null) return false;
            var end = position;
            while (end < source.Length && end - position <= 128 && (char.IsLetterOrDigit(source[end]) || source[end] == '_' || IsMark(source[end]))) end++;
            return end - position <= 128 && knownNames.Contains(source[position..end]);
        }
    }
}
