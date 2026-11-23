namespace Calc.Core;

internal sealed record TimestampJoinExpression(Expression Date, Expression Time) : Expression;
internal sealed record ZoneExpression(Expression Operand, string Zone, bool Conversion, string Ambiguity = "") : Expression;
internal sealed record UnixExpression(Expression Operand, bool Export) : Expression;
internal sealed record NowExpression : Expression;
internal sealed record UnitOrZoneExpression(Expression Operand, string Zone, UnitExpression Unit, bool Conversion) : Expression;

internal sealed partial class ExpressionParser
{
    private bool TryZone(out string zone, bool explicitTarget = false)
    {
        zone = "";
        if (!explicitTarget && KnownNameLength(position) > 0) return false;
        if (Current.Kind == TokenKind.Zone) { zone = Current.Text; position++; return true; }
        var text = ""; var best = position; var id = "";
        for (var cursor = position; cursor < tokens.Count && cursor - position < 16 && (tokens[cursor].Kind == TokenKind.Name || tokens[cursor].Text == "-"); cursor++)
        {
            if (cursor + 1 < tokens.Count && tokens[cursor + 1].Text == "(") break;
            text += (cursor == position || tokens[cursor].JoinedToPrevious ? "" : " ") + tokens[cursor].Text;
            if (ZoneCatalog.TryAlias(text, out var candidate)) { best = cursor + 1; id = candidate; }
        }
        if (best == position) return false;
        position = best; zone = id;
        if (zone == "UTC" && Current.JoinedToPrevious && Current.Text is "+" or "-" && position + 1 < tokens.Count && tokens[position + 1].Kind == TokenKind.Time)
        {
            var sign = Current.Text; position++;
            if (Current.Kind != TokenKind.Time) throw new FormatException("UTC offset requires ±HH:mm[:ss]");
            zone += sign + Current.Text; position++;
        }
        return true;
    }
    private bool TryTimestampTail(ref Expression expression)
    {
        if (Current.Kind == TokenKind.Time || Current.Kind == TokenKind.Symbol && Current.Text == "T" || Current.Text.Equals("at", StringComparison.OrdinalIgnoreCase) && KnownNameLength(position) == 0)
        {
            if (Current.Kind != TokenKind.Time) position++;
            var right=Unary(false);
            expression = new TimestampJoinExpression(expression, right); return true;
        }
        var start = position;
        if (TryZone(out var zone))
        {
            var zoneEnd = position; var unitEnd = start;
            if (UnitParser.TryParse(tokens, ref unitEnd, knownNames, out var unit) && unitEnd == zoneEnd)
            { expression = new UnitOrZoneExpression(expression, zone, unit, false); return true; }
            var ambiguity = Current.Text.ToLowerInvariant() is "earlier" or "later" ? Current.Text.ToLowerInvariant() : "";
            if (ambiguity != "") position++;
            expression = new ZoneExpression(expression, zone, false, ambiguity); return true;
        }
        // ISO offsets bind only when adjacent to a timestamp/closing parenthesis, never ordinary clock subtraction.
        if (Current.JoinedToPrevious && Current.Text is "+" or "-" && position + 1 < tokens.Count && tokens[position + 1].Kind == TokenKind.Time &&
            expression is TimestampJoinExpression)
        {
            zone = "UTC" + Current.Text + tokens[position + 1].Text; position += 2;
            expression = new ZoneExpression(expression, zone, false); return true;
        }
        return false;
    }
}
