using Calc.Core;

namespace Calc.Documents;

/// <summary>
/// Results for text that is still being evaluated. Lines before and after the edited block keep the results
/// of the last evaluation, shifted by the lines added or removed; edited lines have none until the new results land.
/// </summary>
public static class CarriedResults
{
    private static readonly LineResult[] None = [];

    /// <param name="results">One result per line of <paramref name="evaluatedSource"/>, as the last evaluation produced.</param>
    /// <returns>One result per line of <paramref name="source"/>; an edited line gets an empty result.</returns>
    public static IReadOnlyList<LineResult> Map(IReadOnlyList<LineResult> results, string evaluatedSource, string source)
    {
        if (results.Count == 0) return None;
        if (string.Equals(source, evaluatedSource, StringComparison.Ordinal)) return results;
        var old = new SourceLineMap(evaluatedSource); var now = new SourceLineMap(source);
        if (results.Count != old.Count) return None;
        var prefix = 0;
        while (prefix < old.Count && prefix < now.Count && Same(old, prefix, now, prefix)) prefix++;
        var suffix = 0;
        while (suffix < old.Count - prefix && suffix < now.Count - prefix && Same(old, old.Count - 1 - suffix, now, now.Count - 1 - suffix)) suffix++;
        var carried = new LineResult[now.Count];
        for (var i = 0; i < now.Count; i++)
        {
            var fromEnd = now.Count - 1 - i;
            carried[i] = i < prefix ? results[i] : fromEnd < suffix ? results[old.Count - 1 - fromEnd] : new LineResult(i, null, null);
        }
        return carried;
    }

    private static bool Same(SourceLineMap a, int lineA, SourceLineMap b, int lineB) =>
        a.Source.AsSpan(a.Start(lineA), a.ContentEnd(lineA) - a.Start(lineA))
            .SequenceEqual(b.Source.AsSpan(b.Start(lineB), b.ContentEnd(lineB) - b.Start(lineB)));
}
