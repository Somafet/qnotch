namespace Calc.Core;

internal sealed record CountdownExpression(Expression Deadline) : Expression;
internal sealed record CountdownZoneExpression(Expression Deadline, string Zone, string Ambiguity) : Expression;
internal sealed record CalendarEventExpression(int Month = 0, int Day = 0, DayOfWeek? Weekday = null) : Expression;

internal sealed partial class ExpressionParser
{
    private bool TryCalendarEvent(out Expression expression)
    {
        expression = null!;
        if (KnownNameLength(position) > 0 || position + 1 < tokens.Count && tokens[position + 1].Text == "(") return false;
        if (Current.Kind == TokenKind.Name && Enum.TryParse<DayOfWeek>(Current.Text, true, out var day))
        { position++; expression = new CalendarEventExpression(Weekday: day); return true; }
        if (Take("christmas")) { expression = new CalendarEventExpression(12, 25); return true; }
        if (Current.Text.Equals("new", StringComparison.OrdinalIgnoreCase) && position + 1 < tokens.Count && tokens[position + 1].Text.ToLowerInvariant() is "year" or "years")
        {
            position += 2; _ = Take("day"); expression = new CalendarEventExpression(1, 1); return true;
        }
        if (DateSyntax.TryRecurringLiteral(tokens, position, out var month, out var date, out var length))
        { position += length; expression = new CalendarEventExpression(month, date); return true; }
        return false;
    }
    private bool StartsCountdown() => Current.Text.Equals("until", StringComparison.OrdinalIgnoreCase) && KnownNameLength(position) == 0 &&
        (position + 1 >= tokens.Count || tokens[position + 1].Text != "(");
    private Expression ParseCountdown()
    {
        position++; var deadline = Sum();
        while (true)
        {
            var saved = position;
            if (!(Take("in") || Take("to"))) break;
            if (!TryZone(out var zone, true)) { position = saved; break; }
            var ambiguity = Current.Text.ToLowerInvariant() is "earlier" or "later" ? Current.Text.ToLowerInvariant() : "";
            if (ambiguity != "") position++;
            deadline = new CountdownZoneExpression(deadline, zone, ambiguity);
        }
        return RoundingTail(new CountdownExpression(deadline));
    }
}
