namespace Calc.Core;

internal sealed record ImaginaryExpression(Rational Coefficient) : Expression;

internal sealed partial class ExpressionParser
{
    /// <summary>A number joined to a lowercase i, as in 4i. A variable named i keeps the old meaning.</summary>
    private bool TryImaginaryLiteral(out Expression imaginary)
    {
        imaginary = null!;
        if (Current.Kind != TokenKind.Number || position + 1 >= tokens.Count) return false;
        var suffix = tokens[position + 1];
        if (suffix.Kind != TokenKind.Name || suffix.Text != "i" || !suffix.JoinedToPrevious || KnownNameLength(position + 1) > 0) return false;
        imaginary = new ImaginaryExpression(Rational.Parse(Current.Text)); position += 2; return true;
    }
    /// <summary>A constant or i ends at a conversion or rounding tail instead of absorbing it into a multi-word name.</summary>
    private bool StartsValueTail() => Current.Text.Equals("in", StringComparison.OrdinalIgnoreCase) || KeywordCatalog.Match(tokens, position, KeywordRole.To) > 0 ||
        KeywordCatalog.Match(tokens, position, KeywordRole.LeadingDecimals) > 0 || KeywordCatalog.Match(tokens, position, KeywordRole.LeadingSignificant) > 0;
}
