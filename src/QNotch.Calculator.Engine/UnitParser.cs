using System.Numerics;

namespace Calc.Core;

internal static class UnitParser
{
    /// <summary>`l/100km` is one fuel-consumption unit, not litres divided by a hundred kilometres; the magnitude is the same.</summary>
    private static bool TryLitresPer100Km(IReadOnlyList<Token> tokens, int start, HashSet<string>? names) =>
        start + 3 < tokens.Count && tokens[start].Kind == TokenKind.Name && names?.Contains(tokens[start].Text) != true && UnitCatalog.TryGet(tokens[start].Text, out var litre) && litre.Id == "L" &&
        tokens[start + 1].Text == "/" && tokens[start + 2].Kind == TokenKind.Number && tokens[start + 2].Text == "100" && tokens[start + 3].Kind == TokenKind.Name &&
        names?.Contains(tokens[start + 3].Text) != true && UnitCatalog.TryGet(tokens[start + 3].Text, out var kilometre) && kilometre.Id == "km";
    internal static bool TryParse(IReadOnlyList<Token> tokens, ref int position, HashSet<string>? names, out UnitExpression unit)
    {
        var cursor = position; var factors = 0;
        bool Atom(out UnitExpression result)
        {
            var start = cursor; var prefixPower = 1;
            if (cursor < tokens.Count && tokens[cursor].Text.ToLowerInvariant() is "sq" or "square" or "cubic")
            { prefixPower = tokens[cursor++].Text.Equals("cubic", StringComparison.OrdinalIgnoreCase) ? 3 : 2; }
            if (cursor >= tokens.Count || tokens[cursor].Kind != TokenKind.Name || names?.Contains(tokens[cursor].Text) == true ||
                cursor + 1 < tokens.Count && tokens[cursor + 1].Text == "(" && tokens[cursor + 1].JoinedToPrevious || !UnitCatalog.TryToken(tokens[cursor].Text, out result!))
            { cursor = start; result = null!; return false; }
            cursor++;
            if (tokens[cursor - 1].Text.Equals("mpg", StringComparison.OrdinalIgnoreCase) && cursor < tokens.Count && tokens[cursor].Kind == TokenKind.Name && names?.Contains(tokens[cursor].Text) != true &&
                tokens[cursor].Text.ToLowerInvariant() is "uk" or "imp" or "imperial" or "us") result = UnitExpression.Single(UnitCatalog.ById(tokens[cursor++].Text.ToLowerInvariant() == "us" ? "mpg" : "mpguk"));
            if (prefixPower != 1) result = result.Power(new(prefixPower, 1));
            if (cursor < tokens.Count && tokens[cursor].Text == "^")
            {
                cursor++; var sign = 1;
                if (cursor < tokens.Count && tokens[cursor].Text is "+" or "-") { if (tokens[cursor].Text == "-") sign = -1; cursor++; }
                if (cursor >= tokens.Count || tokens[cursor].Kind != TokenKind.Number) throw new FormatException("Unit power requires an integer");
                var exponent = Rational.Parse(tokens[cursor++].Text);
                if (exponent.Denominator != 1 || BigInteger.Abs(exponent.Numerator) > 16) throw new ArithmeticException("Unit power must be an integer from -16 to 16");
                result = result.Power(new(sign * exponent.Numerator, 1));
            }
            if (++factors > 16) throw new ArithmeticException("Unit expression limit exceeded");
            return true;
        }
        if (TryLitresPer100Km(tokens, cursor, names)) { position = cursor + 4; unit = UnitExpression.Single(UnitCatalog.ById("l100km")); return true; }
        var reciprocal = cursor < tokens.Count && (tokens[cursor].Text == "/" || tokens[cursor].Text.Equals("per", StringComparison.OrdinalIgnoreCase));
        if (reciprocal) cursor++;
        if (!Atom(out unit!)) return false;
        if (reciprocal) unit = unit.Power(new(-1, 1));
        while (cursor + 1 < tokens.Count && (tokens[cursor].Text is "*" or "/" || tokens[cursor].Text.Equals("per", StringComparison.OrdinalIgnoreCase)))
        {
            var separator = cursor; var sign = tokens[cursor++].Text == "*" ? 1 : -1;
            if (!Atom(out var next)) { cursor = separator; break; }
            unit = unit.Combine(next, sign);
        }
        position = cursor; return true;
    }
}
