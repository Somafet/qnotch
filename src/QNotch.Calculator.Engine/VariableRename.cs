namespace Calc.Core;

/// <summary>A UTF-16 range of sheet source.</summary>
public readonly record struct SourceSpan(int Start, int Length)
{
    public int End => Start + Length;
}

/// <summary>Lexical rename of a sheet variable. A variable is a name defined by an assignment line; its definitions and
/// references are found outside headings, comments, quoted text, tags, raw command payloads and function definitions.
/// Multi-word names match greedily, so renaming <c>rent</c> leaves <c>monthly rent</c> alone.</summary>
public static class VariableRename
{
    public enum Problem { None, Invalid, Taken }

    /// <summary>The spelling written for a name: words separated by single spaces.</summary>
    public static string Normalize(string name) => SheetSyntax.NormalizeName(name);

    /// <summary>The variable at a caret (empty selection) or exactly covered by a selection, or null.</summary>
    public static (string Name, SourceSpan Span)? Find(string source, int start, int length, CancellationToken cancellationToken = default)
    {
        if (start < 0 || length < 0 || start + length > source.Length) return null;
        if (length > 0)
        {
            // Surrounding whitespace in a selection is not part of the name.
            while (length > 0 && char.IsWhiteSpace(source[start])) { start++; length--; }
            while (length > 0 && char.IsWhiteSpace(source[start + length - 1])) length--;
        }
        var names = DefinedNames(source, cancellationToken);
        if (names.Count == 0) return null;
        var lineStart = source.LastIndexOf('\n', Math.Max(0, start - 1)) + 1;
        if (start == 0) lineStart = 0;
        var lineEnd = source.IndexOf('\n', start + length); if (lineEnd < 0) lineEnd = source.Length;
        foreach (var (name, span) in Scan(source, lineStart, lineEnd, names, cancellationToken))
            if (length == 0 ? span.Start <= start && start <= span.End : span.Start == start && span.Length == length)
                return (name, span);
        return null;
    }

    /// <summary>Every definition and reference of <paramref name="name"/>, in source order.</summary>
    public static IReadOnlyList<SourceSpan> Occurrences(string source, string name, CancellationToken cancellationToken = default)
    {
        var names = DefinedNames(source, cancellationToken);
        var target = SheetSyntax.NormalizeName(name);
        if (!names.Contains(target)) return [];
        return Scan(source, 0, source.Length, names, cancellationToken)
            .Where(found => found.Name.Equals(target, StringComparison.OrdinalIgnoreCase)).Select(found => found.Span).ToArray();
    }

    /// <summary>Whether <paramref name="newName"/> may replace <paramref name="oldName"/> in this sheet.</summary>
    public static Problem Check(string source, string oldName, string newName, CancellationToken cancellationToken = default)
    {
        var normalized = SheetSyntax.NormalizeName(newName);
        if (!SheetSyntax.ValidName(normalized)) return Problem.Invalid;
        if (normalized.Equals(SheetSyntax.NormalizeName(oldName), StringComparison.OrdinalIgnoreCase)) return Problem.None;
        return DefinedNames(source, cancellationToken).Contains(normalized) ? Problem.Taken : Problem.None;
    }

    /// <summary>The source with every occurrence of <paramref name="oldName"/> renamed, or null when the rename is not allowed.</summary>
    public static string? Apply(string source, string oldName, string newName, CancellationToken cancellationToken = default)
    {
        if (Check(source, oldName, newName, cancellationToken) != Problem.None) return null;
        var replacement = SheetSyntax.NormalizeName(newName);
        var text = new System.Text.StringBuilder(source);
        foreach (var span in Occurrences(source, oldName, cancellationToken).Reverse()) text.Remove(span.Start, span.Length).Insert(span.Start, replacement);
        return text.ToString();
    }

    private static HashSet<string> DefinedNames(string source, CancellationToken cancellationToken)
    {
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (start, end) in Lines(source, 0, source.Length))
        {
            var line = source[start..end];
            if (!line.Contains('=')) continue;
            if (SheetSyntax.Scan(line, cancellationToken).Assignment is { } name) names.Add(name);
        }
        return names;
    }

    private static IEnumerable<(int Start, int End)> Lines(string source, int from, int to)
    {
        for (var start = from; start <= to;)
        {
            var end = source.IndexOf('\n', start, to - start); if (end < 0) end = to;
            var trimmed = end > start && source[end - 1] == '\r' ? end - 1 : end;
            yield return (start, trimmed);
            start = end + 1;
        }
    }

    private static List<(string Name, SourceSpan Span)> Scan(string source, int from, int to, HashSet<string> names, CancellationToken cancellationToken)
    {
        var found = new List<(string, SourceSpan)>();
        var maxWords = names.Max(name => name.Count(c => c == ' ') + 1);
        foreach (var (start, end) in Lines(source, from, to))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = source[start..end];
            var trimmed = line.TrimStart();
            if (trimmed.Length == 0 || trimmed == "#" || trimmed.StartsWith("# ", StringComparison.Ordinal)) continue;
            if (line.Contains('=') && SheetSyntax.Scan(line, cancellationToken) is { Directive: not null } or { FunctionName: not null }) continue;
            var words = Words(line);
            for (var w = 0; w < words.Count;)
            {
                var matched = 0;
                for (var k = Math.Min(maxWords, words.Count - w); k >= 1 && matched == 0; k--)
                {
                    if (!Chained(line, words, w, k)) continue;
                    var candidate = string.Join(' ', words.Skip(w).Take(k).Select(word => line[word.Start..word.End]));
                    if (!names.Contains(candidate)) continue;
                    found.Add((SheetSyntax.NormalizeName(candidate), new SourceSpan(start + words[w].Start, words[w + k - 1].End - words[w].Start)));
                    matched = k;
                }
                w += Math.Max(1, matched);
            }
        }
        return found;
    }

    // Words of a multi-word name are separated by whitespace only.
    private static bool Chained(string line, List<(int Start, int End)> words, int first, int count)
    {
        for (var i = first + 1; i < first + count; i++)
            for (var c = words[i - 1].End; c < words[i].Start; c++)
                if (!char.IsWhiteSpace(line[c])) return false;
        return true;
    }

    private static bool WordPart(char c) => char.IsLetterOrDigit(c) || c == '_' || KeywordCatalog.IsMark(c);

    private static List<(int Start, int End)> Words(string line)
    {
        var words = new List<(int, int)>();
        var raw = TextSyntax.RawPayloadStart(line);
        var limit = raw >= 0 ? raw : line.Length;
        for (var i = 0; i < limit;)
        {
            var c = line[i];
            if (c == '/' && i + 1 < limit && line[i + 1] == '/') break;
            if (c == '"')
            {
                for (i++; i < limit && line[i] != '"'; i++) if (line[i] == '\\') i++;
                i++; continue;
            }
            if (c == '#')
            {
                var colour = DeveloperSyntax.ColourLiteralLength(line, i);
                if (colour > 0) { i += colour; continue; }
                for (i++; i < limit && (WordPart(line[i]) || line[i] == '-'); i++) { }
                continue;
            }
            if (char.IsDigit(c)) { while (i < limit && (char.IsDigit(line[i]) || line[i] is '.' or '_')) i++; continue; }
            if (char.IsLetter(c) || c == '_')
            {
                var start = i;
                while (i < limit && WordPart(line[i])) i++;
                words.Add((start, i)); continue;
            }
            i++;
        }
        return words;
    }
}
