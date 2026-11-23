namespace Calc.Core;

internal sealed record ResistorLiteralExpression(string[] Bands) : Expression;

internal sealed partial class ExpressionParser
{
    private Expression Parallel()
    {
        var expression = Product();
        while (Take("||")) expression = new BinaryExpression("||", expression, Product());
        return expression;
    }
    private bool TryResistorLiteral(out Expression expression)
    {
        expression = null!;
        if (KnownNameLength(position) > 0 || position + 1 < tokens.Count && tokens[position + 1].Text == "(") return false;
        var cursor = position; var bands = new List<string>();
        while (cursor < tokens.Count && tokens[cursor].Kind == TokenKind.Name && ResistorColorCatalog.TryGet(tokens[cursor].Text, out var color))
        {
            if (bands.Count == 5) throw new FormatException("Resistor markings support at most five bands");
            bands.Add(color.Name); cursor++;
        }
        if (bands.Count < 3) return false;
        position = cursor; expression = new ResistorLiteralExpression(bands.ToArray()); return true;
    }
}
