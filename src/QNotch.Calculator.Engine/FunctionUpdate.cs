namespace Calc.Core;

/// <summary>Pure proposed save. Persistence belongs to Documents, never evaluation.</summary>
public sealed record FunctionUpdate(FunctionLibrary Library, IReadOnlyList<FunctionReceipt> Receipts, string SourceHash, bool HasChanges)
{
    public string BaseFingerprint { get; init; } = "";
    internal IReadOnlyDictionary<int, string> Errors { get; init; } = new Dictionary<int, string>();
    internal HashSet<string> BlockedNames { get; init; } = new(StringComparer.OrdinalIgnoreCase);
    internal string CacheKey => Library.Fingerprint + ":" + string.Join(',', BlockedNames.Order(StringComparer.OrdinalIgnoreCase));

    public static FunctionUpdate Prepare(string source, FunctionLibrary library, IReadOnlyList<FunctionReceipt> receipts, CancellationToken token = default)
    {
        if (source.Length > SheetEvaluator.MaxCharacters) throw new ArgumentException("Sheet exceeds 200,000 characters");
        var lines = source.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        if (lines.Length > SheetEvaluator.MaxLines) throw new ArgumentException("Sheet exceeds 10,000 lines");
        var tables = TableSyntax.Layout(lines, token);
        return Prepare(source, lines.Select((line, i) => tables.Scan(i, lines, token) ?? SheetSyntax.Scan(line, token)).ToArray(), library, receipts, token);
    }
    internal static FunctionUpdate Prepare(string source, ParsedLine[] lines, FunctionLibrary library, IReadOnlyList<FunctionReceipt> receipts, CancellationToken token)
    {
        ValidateReceipts(receipts);
        var before = receipts.ToDictionary(r => r.Key, r => r.Count, StringComparer.Ordinal);
        var seen = new Dictionary<string, int>(StringComparer.Ordinal);
        var proposed = library.Definitions.ToDictionary(d => d.Name, StringComparer.OrdinalIgnoreCase);
        var pending = new List<(int Line, FunctionDirective Command)>();
        var errors = new Dictionary<int, string>(); var blocked = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var directiveCount = 0;
        foreach (var (line, index) in lines.Select((line, i) => (line, i)))
        {
            token.ThrowIfCancellationRequested();
            if (line.FunctionName is { } invalidName && line.Error is not null) blocked.Add(invalidName);
            if (line.Directive is not { } command) continue;
            var count = seen.GetValueOrDefault(command.Key) + 1; seen[command.Key] = count;
            if (++directiveCount > 256) { errors[index] = "Function directive limit exceeded"; blocked.Add(command.Name); continue; }
            if (count <= before.GetValueOrDefault(command.Key)) continue;
            pending.Add((index, command));
            if (command.Definition is { } definition) proposed[command.Name] = definition;
            else proposed.Remove(command.Name);
        }
        FunctionLibrary projected = library;
        if (pending.Count > 0 && errors.Count == 0 && blocked.Count == 0)
        {
            try { projected = new(proposed.Values, token); }
            catch (Exception e) when (e is FormatException or ArithmeticException)
            { foreach (var entry in pending) { errors[entry.Line] = e.Message; blocked.Add(entry.Command.Name); } }
        }
        if (blocked.Count > 0 || errors.Count > 0)
            foreach (var entry in pending) { errors.TryAdd(entry.Line, "Function changes not applied; fix invalid definitions"); blocked.Add(entry.Command.Name); }
        var next = seen.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => new FunctionReceipt(p.Key,
            errors.Count == 0 && blocked.Count == 0 ? p.Value : Math.Min(p.Value, before.GetValueOrDefault(p.Key)))).Where(r => r.Count > 0).ToArray();
        var changed = projected.Fingerprint != library.Fingerprint || !receipts.OrderBy(r => r.Key, StringComparer.Ordinal).SequenceEqual(next);
        return new(projected, Array.AsReadOnly(next), FunctionLibrary.Hash(source), changed) { BaseFingerprint = library.Fingerprint, Errors = errors, BlockedNames = blocked };
    }
    public static void ValidateReceipts(IReadOnlyList<FunctionReceipt> receipts)
    {
        if (receipts is null || receipts.Count > 256 || receipts.Any(r => r is null || r.Key is null || r.Key.Length != 64 || !r.Key.All(c => char.IsAsciiHexDigit(c)) || r.Count is < 1 or > 256) ||
            receipts.Select(r => r.Key).Distinct(StringComparer.Ordinal).Count() != receipts.Count || receipts.Sum(r => r.Count) > 256)
            throw new FormatException("Invalid function receipts");
    }
}
