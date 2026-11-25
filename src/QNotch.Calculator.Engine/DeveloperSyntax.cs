namespace Calc.Core;

internal sealed record ColourLiteralExpression(string Text) : Expression;

public static class DeveloperSyntax
{
    /// <summary>Recognize a hex colour only where an operand may begin; trailing #face stays a sheet tag.</summary>
    public static int ColourLiteralLength(string source, int start)
    {
        if (start < 0 || start >= source.Length || source[start] != '#') return 0;
        var before = start - 1; while (before >= 0 && char.IsWhiteSpace(source[before])) before--;
        if (before >= 0 && source[before] is not ('=' or '(' or ',')) return 0;
        var end = start + 1; while (end < source.Length && end - start <= 9 && char.IsAsciiHexDigit(source[end])) end++;
        if (end < source.Length && (char.IsLetterOrDigit(source[end]) || source[end] is '_' or '-')) return 0;
        return end - start - 1 is 3 or 4 or 6 or 8 ? end - start : 0;
    }
    internal static int CodepointLength(string source, int start)
    {
        if (start + 6 > source.Length || char.ToUpperInvariant(source[start]) != 'U' || source[start + 1] != '+') return 0;
        var end = start + 2; while (end < source.Length && char.IsAsciiHexDigit(source[end])) end++;
        if (end - start - 2 is < 4 or > 6 || end < source.Length && (char.IsLetterOrDigit(source[end]) || source[end] == '_')) return 0;
        return end - start;
    }
    internal static bool TryAspect(string source, int start, out int end, out string dimensions)
    {
        end = start; dimensions = ""; var i = start;
        string? Number()
        {
            var first = i; var dots = 0; var digits = 0;
            while (i < source.Length && i - first <= 256 && (char.IsAsciiDigit(source[i]) || source[i] == '.')) { if (source[i++] == '.') dots++; else digits++; }
            return digits > 0 && dots <= 1 && i - first <= 256 ? source[first..i] : null;
        }
        var width = Number(); if (width is null) return false;
        while (i < source.Length && char.IsWhiteSpace(source[i])) i++;
        if (i == source.Length || source[i] is not ('x' or '×')) return false; i++;
        while (i < source.Length && char.IsWhiteSpace(source[i])) i++;
        var height = Number(); if (height is null) return false;
        var space = i; while (i < source.Length && char.IsWhiteSpace(source[i])) i++;
        if (i == space || !source.AsSpan(i).StartsWith("aspect", StringComparison.OrdinalIgnoreCase)) return false;
        i += 6; if (i < source.Length && (char.IsLetterOrDigit(source[i]) || source[i] == '_')) return false;
        end = i; dimensions = width + "x" + height; return true;
    }
}
