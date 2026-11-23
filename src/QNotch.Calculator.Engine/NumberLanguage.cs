namespace Calc.Core;

internal static class NumberLanguage
{
    internal static int CjkExponent(string text) => text switch { "万" or "만" => 4, "億" or "亿" or "억" => 8, _ => 0 };
    internal static bool IsCjkScale(char value) => value is '万' or '億' or '亿' or '만' or '억';
    internal static bool IsShortSuffix(string text) => text is "k" or "K" or "M" or "B";
    internal static bool TryMultiplier(string text, bool attached, out Rational factor)
    {
        var exponent = CjkExponent(text);
        if (exponent == 0 && attached) exponent = text switch { "k" or "K" => 3, "M" => 6, "B" => 9, _ => 0 };
        if (exponent == 0) exponent = text.ToLowerInvariant() switch
        {
            "thousand" or "thousands" => 3, "million" or "millions" => 6, "billion" or "billions" => 9, _ => 0
        };
        factor = exponent == 0 ? default : new(System.Numerics.BigInteger.Pow(10, exponent), 1);
        return exponent != 0;
    }
    internal static string CanonicalToken(IReadOnlyList<Token> tokens, int index)
    {
        var token = tokens[index]; var text = token.Text.ToUpperInvariant();
        if (token.Kind == TokenKind.Date) return "@DATE:" + text;
        if (token.Kind == TokenKind.Time) return "@TIME:" + text;
        if (token.Kind == TokenKind.Zone) return "@ZONE:" + token.Text;
        if (index > 0 && token.JoinedToPrevious && token.Text is "+" or "-" && index + 1 < tokens.Count && tokens[index + 1].Kind == TokenKind.Time)
            return "@ADJACENT:" + token.Text;
        if (index > 0 && token.JoinedToPrevious)
        {
            var previous = tokens[index - 1];
            // Preserve old canonical hashes except where newly supported syntax gives whitespace a meaning.
            if (previous.Kind == TokenKind.Number && token.Kind == TokenKind.Name && IsShortSuffix(token.Text)) return "@SCALE:" + text;
            if (previous.Kind == TokenKind.Name && CjkExponent(previous.Text) != 0 && token.Kind == TokenKind.Number) return "@GROUP:" + text;
        }
        return text;
    }
}
