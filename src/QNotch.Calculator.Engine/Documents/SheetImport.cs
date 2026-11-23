using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Calc.Core;

namespace Calc.Documents;

public enum ImportFormat { Text, Numi, Soulver }
/// <summary>Something the import changed, could not translate or Calc cannot evaluate. Line is 1-based; 0 means the whole file.</summary>
public sealed record ImportNotice(int Line, string Message);
public sealed record ImportedSheet(string Name, string Source, ImportFormat Format, IReadOnlyList<ImportNotice> Notices);
/// <summary>The file was not imported. Nothing was created and the original file was only read.</summary>
public sealed class ImportRejectedException(string message) : IOException(message);

/// <summary>Reads Numi (.numi), Soulver (.slvr) and plain text (.txt) files into new-sheet sources (X04).
/// Pure data transformation: no file is written, nothing from the content is executed, and no provider or network is involved.
/// Format assumptions are recorded in docs/windows/p6-import.md.</summary>
public static class SheetImport
{
    public const long MaxTextBytes = 1_000_000;
    public const long MaxSoulverBytes = 4_000_000;
    public const int MaxFiles = 32;
    public const int MaxNotices = 200;
    public const int MaxJsonDepth = 64;
    public const int MaxJsonNodes = 200_000;
    public static readonly TimeSpan EvaluationCheckLimit = TimeSpan.FromSeconds(5);
    private static readonly string[] TextKeys = ["expression", "text", "input", "string", "content", "line", "value"];
    private static readonly string[] BodyKeys = ["text", "content", "body", "source", "sheet", "string"];
    private static readonly string[] IdKeys = ["id", "uuid", "identifier", "lineid", "lineidentifier", "lineuuid"];
    private static readonly Regex GuidToken = new(@"[\[{<⟨]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}[\]}>⟩]?", RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));

    public static ImportFormat? FormatFor(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".numi" => ImportFormat.Numi, ".slvr" => ImportFormat.Soulver, ".txt" => ImportFormat.Text, _ => null
    };
    public static bool IsSupported(string path) => FormatFor(path) is not null;

    /// <summary>Reads at most the bounded size, then parses. The file is opened read-only and shared for reading.</summary>
    public static ImportedSheet ReadFile(string path, CancellationToken cancellationToken = default)
    {
        var format = FormatFor(path) ?? throw new ImportRejectedException("Unsupported file type; use .numi, .slvr or .txt");
        var limit = format == ImportFormat.Soulver ? MaxSoulverBytes : MaxTextBytes;
        var info = new FileInfo(path);
        if (!info.Exists) throw new ImportRejectedException("File not found");
        byte[] bytes;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan))
        {
            if (stream.Length > limit) throw new ImportRejectedException($"File exceeds {limit:N0} bytes; nothing imported");
            bytes = new byte[checked((int)stream.Length)];
            stream.ReadExactly(bytes);
            if (stream.ReadByte() != -1) throw new ImportRejectedException("File changed while reading; nothing imported");
        }
        return Parse(Path.GetFileName(path), bytes, cancellationToken);
    }

    public static ImportedSheet Parse(string fileName, byte[] bytes, CancellationToken cancellationToken = default)
    {
        var format = FormatFor(fileName) ?? throw new ImportRejectedException("Unsupported file type; use .numi, .slvr or .txt");
        var limit = format == ImportFormat.Soulver ? MaxSoulverBytes : MaxTextBytes;
        if (bytes.Length > limit) throw new ImportRejectedException($"File exceeds {limit:N0} bytes; nothing imported");
        var notices = new List<ImportNotice>();
        string source;
        if (format != ImportFormat.Soulver) source = Normalize(Decode(bytes));
        else
        {
            var text = Decode(bytes);
            var start = text.AsSpan().TrimStart();
            source = start.Length > 0 && start[0] is '{' or '['
                ? Soulver(text, notices, cancellationToken)
                : TranslateLineWords(Normalize(text), notices); // Assumption: a non-JSON .slvr is Soulver plain text.
        }
        CheckBounds(source);
        CheckEvaluation(source, notices, cancellationToken);
        if (notices.Count > MaxNotices) { var hidden = notices.Count - MaxNotices; notices.RemoveRange(MaxNotices, hidden); notices.Add(new(0, $"{hidden:N0} more notes not shown")); }
        return new(SheetName(fileName), source, format, notices);
    }

    /// <summary>A valid, unused sheet name derived from the file name.</summary>
    public static string UniqueName(string name, IEnumerable<string> existing)
    {
        var taken = existing.ToHashSet(StringComparer.OrdinalIgnoreCase);
        if (!taken.Contains(name)) return name;
        for (var n = 2; ; n++)
        {
            var suffix = $" {n}";
            var candidate = Truncate(name, WorkspaceStore.MaxNameLength - suffix.Length).TrimEnd() + suffix;
            if (!taken.Contains(candidate)) return candidate;
        }
    }

    public static string SheetName(string fileName)
    {
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var name = string.Join(' ', new string(stem.Select(c => char.IsControl(c) ? ' ' : c).ToArray()).Split(' ', StringSplitOptions.RemoveEmptyEntries));
        name = Truncate(name, WorkspaceStore.MaxNameLength).Trim();
        return name.Length == 0 ? "Imported" : name;
    }
    private static string Truncate(string value, int length)
    {
        if (value.Length <= length) return value;
        if (length > 0 && char.IsHighSurrogate(value[length - 1])) length--;
        return value[..length];
    }

    /// <summary>Strict UTF-8 (optional BOM) or BOM-marked UTF-16. Binary content and control characters other than tab/newlines reject the file.</summary>
    internal static string Decode(byte[] bytes)
    {
        string text;
        try
        {
            if (bytes is [0xEF, 0xBB, 0xBF, ..]) text = new UTF8Encoding(false, true).GetString(bytes, 3, bytes.Length - 3);
            else if (bytes is [0xFF, 0xFE, ..]) text = new UnicodeEncoding(false, false, true).GetString(bytes, 2, bytes.Length - 2);
            else if (bytes is [0xFE, 0xFF, ..]) text = new UnicodeEncoding(true, false, true).GetString(bytes, 2, bytes.Length - 2);
            else text = new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException) { throw new ImportRejectedException("Not valid UTF-8 or UTF-16 text; nothing imported"); }
        var line = 1;
        foreach (var c in text)
        {
            if (c == '\n') line++;
            else if (c is not ('\t' or '\r') && char.IsControl(c))
                throw new ImportRejectedException(c == '\0' ? "Binary content; nothing imported" : $"Control character U+{(int)c:X4} on line {line}; nothing imported");
        }
        return text;
    }
    private static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');
    private static void CheckBounds(string source)
    {
        if (source.Length > SheetStore.MaxCharacters) throw new ImportRejectedException($"Sheet would exceed {SheetStore.MaxCharacters:N0} characters; nothing imported");
        if (source.Count(c => c == '\n') + 1 > SheetEvaluator.MaxLines) throw new ImportRejectedException($"Sheet would exceed {SheetEvaluator.MaxLines:N0} lines; nothing imported");
    }

    /// <summary>Lines Calc cannot evaluate stay exactly as written; each one is reported. A line without a result is reported
    /// when it looks like a calculation (digits/operators) or is a Numi/Soulver aggregate keyword; plain prose labels are not.</summary>
    private static void CheckEvaluation(string source, List<ImportNotice> notices, CancellationToken cancellationToken)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(EvaluationCheckLimit);
        var lines = source.Split('\n');
        try
        {
            foreach (var result in SheetEvaluator.Evaluate(source, limit.Token))
            {
                if (result.Error is { } error) notices.Add(new(result.Line + 1, $"Calc cannot evaluate this line ({error}); kept as written"));
                else if (result.Value is null && !result.IsDeclaration && result.Line < lines.Length && LooksCalculated(lines[result.Line]))
                    notices.Add(new(result.Line + 1, "No result in Calc; kept as written"));
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        { notices.Add(new(0, "Evaluation check stopped at its time limit; every line is kept as written")); }
        notices.Sort((a, b) => a.Line.CompareTo(b.Line));
    }
    private static readonly string[] SourceKeywords = ["total", "subtotal", "grand total", "ans"];
    private static bool LooksCalculated(string line)
    {
        var comment = line.IndexOf("//", StringComparison.Ordinal);
        var trimmed = (comment >= 0 ? line[..comment] : line).Trim();
        if (trimmed.Length == 0 || trimmed[0] == '#' || line.Contains('\t')) return false; // Tab rows belong to tables.
        return trimmed.Any(c => char.IsAsciiDigit(c) || c is '+' or '-' or '*' or '/' or '^' or '%' or '=' or '×' or '÷')
            || SourceKeywords.Contains(trimmed.TrimEnd(':').ToLowerInvariant());
    }

    /// <summary>Soulver's documented plain-text reference form "line3" becomes Calc's "L3". Physical numbering is preserved because
    /// the import never adds or removes lines. Headings, // comments and quoted text are left alone.</summary>
    internal static string TranslateLineWords(string source, List<ImportNotice> notices)
    {
        var lines = source.Split('\n');
        for (var i = 0; i < lines.Length; i++) lines[i] = TranslateLineWords(lines[i], i + 1, lines.Length, notices);
        return string.Join('\n', lines);
    }
    private static string TranslateLineWords(string line, int number, int count, List<ImportNotice> notices)
    {
        if (line.TrimStart().StartsWith('#') || !line.Contains("line", StringComparison.OrdinalIgnoreCase)) return line;
        var output = new StringBuilder(line.Length); var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (c == '"') quoted = !quoted;
            if (!quoted && c == '/' && i + 1 < line.Length && line[i + 1] == '/') { output.Append(line, i, line.Length - i); break; }
            if (!quoted && (i == 0 || !Word(line[i - 1])) && i + 4 < line.Length && string.Compare(line, i, "line", 0, 4, StringComparison.OrdinalIgnoreCase) == 0 && char.IsAsciiDigit(line[i + 4]))
            {
                var end = i + 4;
                while (end < line.Length && char.IsAsciiDigit(line[end])) end++;
                if (end == line.Length || !Word(line[end]))
                {
                    var digits = line[(i + 4)..end];
                    if (int.TryParse(digits, out var target) && target >= 1 && target <= count && target != number)
                    { output.Append('L').Append(target); i = end - 1; continue; }
                    notices.Add(new(number, $"“{line[i..end]}” does not name another line; kept as written"));
                    output.Append(line, i, end - i); i = end - 1; continue;
                }
            }
            output.Append(c);
        }
        return output.ToString();
    }
    private static bool Word(char c) => char.IsLetterOrDigit(c) || c == '_';

    /// <summary>Assumed JSON layout (the schema is not published): either an array of line objects that each carry a text field
    /// and optionally an identifier, or a single text body. Identifier tokens of at least 8 characters inside another line's
    /// text become Calc line references. Every other field is reported, never silently dropped; the original file is untouched.</summary>
    private static string Soulver(string json, List<ImportNotice> notices, CancellationToken cancellationToken)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = MaxJsonDepth }); }
        catch (JsonException e) { throw new ImportRejectedException($"Corrupt Soulver file ({e.Message}); nothing imported"); }
        using (document)
        {
            var nodes = 0;
            var candidates = new List<Candidate>();
            Find(document.RootElement, null, [], candidates, ref nodes, cancellationToken);
            var lines = candidates.Where(c => c.Lines is not null).ToList();
            var chosen = lines.FirstOrDefault(c => c.Key?.Contains("line", StringComparison.OrdinalIgnoreCase) == true)
                ?? lines.OrderByDescending(c => c.Lines!.Length).FirstOrDefault()
                ?? candidates.Where(c => c.Body is not null).OrderBy(c => c.Path.Length).ThenByDescending(c => c.Body!.Length).FirstOrDefault()
                ?? throw new ImportRejectedException("Unrecognized Soulver file structure; nothing imported");
            var consumed = new HashSet<string>(chosen.Path, StringComparer.Ordinal);
            if (chosen.TextKey is not null) consumed.Add(chosen.TextKey);
            if (chosen.IdKey is not null) consumed.Add(chosen.IdKey);
            var ignored = new SortedSet<string>(StringComparer.Ordinal);
            CollectKeys(document.RootElement, consumed, ignored);
            if (ignored.Count > 0)
                notices.Add(new(0, $"Not imported (kept in the original file): {string.Join(", ", ignored.Take(16))}{(ignored.Count > 16 ? $" and {ignored.Count - 16} more" : "")}"));
            if (chosen.Body is not null) return TranslateLineWords(Normalize(chosen.Body), notices);
            var text = new string[chosen.Lines!.Length];
            for (var i = 0; i < text.Length; i++)
            {
                var value = chosen.Lines[i];
                if (value.Contains('\n') || value.Contains('\r'))
                { value = string.Join(' ', Normalize(value).Split('\n')); notices.Add(new(i + 1, "Line contained line breaks; joined with spaces to keep line numbers")); }
                text[i] = value;
            }
            if (chosen.Ids is { } ids) TranslateIdentifiers(text, ids, notices);
            for (var i = 0; i < text.Length; i++) text[i] = TranslateLineWords(text[i], i + 1, text.Length, notices);
            return string.Join('\n', text);
        }
    }

    private sealed record Candidate(string? Key, string[] Path, string[]? Lines, string?[]? Ids, string? TextKey, string? IdKey, string? Body);

    private static void Find(JsonElement element, string? key, string[] path, List<Candidate> candidates, ref int nodes, CancellationToken cancellationToken)
    {
        if (++nodes > MaxJsonNodes) throw new ImportRejectedException("Soulver file is too complex; nothing imported");
        if ((nodes & 1023) == 0) cancellationToken.ThrowIfCancellationRequested();
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (property.Value.ValueKind == JsonValueKind.String && BodyKeys.Contains(property.Name.ToLowerInvariant()) && property.Value.GetString() is { } body && (body.Contains('\n') || path.Length == 0))
                    candidates.Add(new(property.Name, path, null, null, property.Name, null, body));
                Find(property.Value, property.Name, [.. path, property.Name], candidates, ref nodes, cancellationToken);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array)
        {
            if (LineArray(element) is { } found) candidates.Add(found with { Key = key, Path = path });
            foreach (var item in element.EnumerateArray()) Find(item, key, path, candidates, ref nodes, cancellationToken);
        }
    }

    private static Candidate? LineArray(JsonElement array)
    {
        var count = array.GetArrayLength();
        if (count == 0 || array.EnumerateArray().Any(e => e.ValueKind != JsonValueKind.Object)) return null;
        var textKey = TextKeys.Select(k => Property(array[0], k)?.Name).FirstOrDefault(name => name is not null
            && array.EnumerateArray().All(e => e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String));
        if (textKey is null) return null;
        var idKey = IdKeys.Select(k => Property(array[0], k)?.Name).FirstOrDefault(name => name is not null
            && array.EnumerateArray().All(e => e.TryGetProperty(name, out var v) && v.ValueKind is JsonValueKind.String or JsonValueKind.Number));
        var lines = array.EnumerateArray().Select(e => e.GetProperty(textKey).GetString()!).ToArray();
        var ids = idKey is null ? null : array.EnumerateArray().Select(e => e.GetProperty(idKey) is var v && v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText()).ToArray();
        return new(null, [], lines, ids, textKey, idKey, null);
    }
    private static JsonProperty? Property(JsonElement element, string name)
    {
        foreach (var property in element.EnumerateObject()) if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) return property;
        return null;
    }
    private static void CollectKeys(JsonElement element, HashSet<string> consumed, SortedSet<string> ignored)
    {
        if (element.ValueKind == JsonValueKind.Object)
            foreach (var property in element.EnumerateObject())
            {
                if (!consumed.Contains(property.Name)) ignored.Add(property.Name);
                CollectKeys(property.Value, consumed, ignored);
            }
        else if (element.ValueKind == JsonValueKind.Array)
            foreach (var item in element.EnumerateArray()) CollectKeys(item, consumed, ignored);
    }

    /// <summary>Replaces another line's identifier (optionally bracketed) with L{n}. Short identifiers are not translated because
    /// they cannot be told apart from numbers or list syntax. GUID-shaped tokens that match no line are kept and reported.</summary>
    private static void TranslateIdentifiers(string[] lines, string?[] ids, List<ImportNotice> notices)
    {
        var index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < ids.Length; i++)
            if (ids[i] is { Length: >= 8 } id && !index.TryAdd(id, i)) index[id] = -1; // Duplicate identifiers are ambiguous.
        if (index.Count == 0) return;
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            foreach (var (id, target) in index)
            {
                if (target == i || !line.Contains(id, StringComparison.OrdinalIgnoreCase)) continue;
                if (target < 0) { notices.Add(new(i + 1, $"Reference “{id}” is ambiguous; kept as written")); continue; }
                var pattern = $@"(\[|\{{|<|⟨)?(?<![0-9A-Za-z_-]){Regex.Escape(id)}(?![0-9A-Za-z_-])(\]|\}}|>|⟩)?";
                line = Regex.Replace(line, pattern, m => m.Groups[1].Success == m.Groups[2].Success ? $"L{target + 1}" : (m.Groups[1].Value + $"L{target + 1}" + m.Groups[2].Value),
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
            }
            foreach (Match m in GuidToken.Matches(line))
                notices.Add(new(i + 1, $"Reference “{m.Value}” matches no line in this file; kept as written"));
            lines[i] = line;
        }
    }
}
