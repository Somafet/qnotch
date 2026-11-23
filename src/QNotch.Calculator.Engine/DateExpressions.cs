namespace Calc.Core;

internal sealed partial class ExpressionParser
{
    private bool TryDateAnchor(out Expression expression)
    {
        expression = null!;
        if (KnownNameLength(position) > 0 || position + 1 < tokens.Count && tokens[position + 1].Text == "(") return false;
        var text = Current.Text.ToLowerInvariant();
        if (text is "today" or "tomorrow" or "yesterday")
        { position++; expression = new DateAnchorExpression(text == "today" ? 0 : text == "tomorrow" ? 1 : -1); return true; }
        if (text is "next" or "last" && position + 1 < tokens.Count && tokens[position + 1].Kind == TokenKind.Name && Enum.TryParse<DayOfWeek>(tokens[position + 1].Text, true, out var weekday))
        { position += 2; expression = new DateAnchorExpression(Weekday: weekday, Direction: text == "next" ? 1 : -1); return true; }
        return false;
    }
    private bool TryCalendarSuffix(ref Expression expression)
    {
        if (Current.Kind != TokenKind.Name || KnownNameLength(position) > 0) return false;
        var text = Current.Text.ToLowerInvariant();
        if (text is not "month" and not "months" and not "year" and not "years") return false;
        position++; expression = new CalendarPeriodExpression(expression, text is "year" or "years" ? 12 : 1);
        return true;
    }
    private void CompositeTail(ref Expression expression)
    {
        while (Current.Kind == TokenKind.Number)
        {
            var start = position; var next = Number();
            if (!TryCalendarSuffix(ref next))
            {
                if (!UnitParser.TryParse(tokens, ref position, knownNames, out var unit)) { position = start; break; }
                next = new UnitExpressionNode(next, unit, false);
            }
            expression = new BinaryExpression("+", expression, next);
        }
    }
    private bool TryDateSentence(out Expression expression)
    {
        expression = null!;
        if (tokens.Count == 0 || knownNames?.Contains(string.Join(' ', tokens.Select(token => token.Text))) == true) return false;
        Expression Part(int start, int count) => new ExpressionParser(tokens.Skip(start).Take(count).ToArray(), cancellationToken, knownNames, questionDepth + 1).Parse();
        int Separator(string word, int start)
        {
            var nesting = 0;
            for (var index = start; index < tokens.Count; index++)
            {
                if (tokens[index].Text == "(") nesting++;
                else if (tokens[index].Text == ")") nesting--;
                else if (nesting == 0 && tokens[index].Text.Equals(word, StringComparison.OrdinalIgnoreCase)) return index;
            }
            return -1;
        }
        var first = tokens[0].Text.ToLowerInvariant(); var second = tokens.Count > 1 ? tokens[1].Text.ToLowerInvariant() : "";
        if (tokens.Count > 1 && tokens[^1].Text.Equals("ago", StringComparison.OrdinalIgnoreCase))
        { expression = new DateShiftExpression(new DateAnchorExpression(), Part(0, tokens.Count - 1), -1); return true; }
        if (KnownNameLength(0) > 0 || second == "(") return false;
        if (first == "in" && tokens.Count > 1)
        { expression = new DateShiftExpression(new DateAnchorExpression(), Part(1, tokens.Count - 1), 1); return true; }
        if (first is "days" or "weeks" && second is "between" or "since" or "until")
        {
            Expression from, to;
            if (second == "between")
            {
                var split = Separator("and", 2);
                if (split < 0) throw new FormatException("Expected and between date endpoints");
                from = Part(2, split - 2); to = Part(split + 1, tokens.Count - split - 1);
            }
            else
            {
                var endpoint = Part(2, tokens.Count - 2); var today = new DateAnchorExpression();
                from = second == "since" ? endpoint : today; to = second == "since" ? today : endpoint;
            }
            expression = new DateIntervalExpression(first, from, to); return true;
        }
        if (first == "age" && second == "of")
        {
            var split = Separator("on", 2);
            expression = new DateIntervalExpression("age", Part(2, split < 0 ? tokens.Count - 2 : split - 2),
                split < 0 ? new DateAnchorExpression() : Part(split + 1, tokens.Count - split - 1));
            return true;
        }
        return false;
    }
}
