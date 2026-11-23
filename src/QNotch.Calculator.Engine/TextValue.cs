using System.Text;
using System.Text.Json;

namespace Calc.Core;

/// <summary>Exact Unicode scalar text. Preview, raw clipboard text and a reusable expression are separate.</summary>
public sealed record TextValue
{
    public const int MaximumLength = 32768;
    public string Value { get; }
    public string Display { get; }
    public bool CopiesExpression => Value.Contains('\0');
    public string CopyText => CopiesExpression ? ExpressionText : Value;
    public string ExpressionText => "text(" + Quote(Value) + ")";
    public TextValue(string value)
    {
        ArgumentNullException.ThrowIfNull(value); Validate(value); Value = value;
        var preview = value;
        if (preview.Length > 96)
        {
            var left = 64; if (char.IsHighSurrogate(preview[left - 1])) left--;
            var right = preview.Length - 24; if (char.IsLowSurrogate(preview[right])) right++;
            preview = preview[..left] + "…" + preview[right..];
        }
        var shown = new StringBuilder();
        foreach (var rune in preview.EnumerateRunes())
        {
            var n = rune.Value;
            var part = n == '\n' ? "\\n" : n == '\r' ? "\\r" : n == '\t' ? "\\t" :
                n < 32 || n is >= 127 and <= 159 or 0x2028 or 0x2029 or 0x200e or 0x200f or >= 0x202a and <= 0x202e or >= 0x2066 and <= 0x2069 ?
                    "\\u" + n.ToString("X4", System.Globalization.CultureInfo.InvariantCulture) : rune.ToString();
            if (shown.Length + part.Length > 124) { shown.Append('…'); break; } shown.Append(part);
        }
        Display = value.Length == 0 ? "\"\"" : shown.ToString();
    }
    internal static void Validate(string text)
    {
        if (text.Length > MaximumLength) throw new ArithmeticException("Text exceeds 32768 UTF-16 code units");
        for (var i = 0; i < text.Length; i++)
        {
            if (!char.IsSurrogate(text[i])) continue;
            if (!char.IsHighSurrogate(text[i]) || i + 1 == text.Length || !char.IsLowSurrogate(text[++i])) throw new FormatException("Text contains an unpaired UTF-16 surrogate");
        }
    }
    internal static string Quote(string text) => JsonSerializer.Serialize(text);
}

public sealed record TextTransformEvidence(string Operation, string Input, string Output, int InputUtf8Bytes, int OutputUtf8Bytes, string InputBytePreview, string InputPreview);
