namespace Calc.Core;

internal sealed record WorkdayPeriodExpression(Expression Count) : Expression;
internal sealed record WorkdayCountExpression(Expression From, Expression To) : Expression;
internal sealed record AnnualHolidayExpression(int Month, int Day) : Expression;

internal sealed partial class ExpressionParser
{
    internal static bool WorkdayPrefix(IReadOnlyList<Token> values, int at, out int length)
    {
        length = 0; if (at >= values.Count) return false;
        var word = values[at].Text.ToLowerInvariant();
        if (word is "workday" or "workdays") length = 1;
        else if (word is "working" or "business" && at + 1 < values.Count && values[at + 1].Text.ToLowerInvariant() is "day" or "days") length = 2;
        return length != 0;
    }
    private bool TryWorkdaySuffix(ref Expression expression)
    {
        if (KnownNameLength(position) > 0 || !WorkdayPrefix(tokens, position, out var length)) return false;
        position += length; expression = new WorkdayPeriodExpression(expression); return true;
    }
    private bool TryWorkdaySentence(out Expression expression)
    {
        expression = null!;
        if (tokens.Count == 0 || KnownNameLength(0) > 0 || !WorkdayPrefix(tokens, 0, out var length)) return false;
        if (length >= tokens.Count) return false;
        var word = tokens[length].Text.ToLowerInvariant();
        Expression Part(int start, int count) => new ExpressionParser(tokens.Skip(start).Take(count).ToArray(), cancellationToken, knownNames, questionDepth + 1).Parse();
        if (word == "between")
        {
            var nesting = 0; var split = -1;
            for (var index = length + 1; index < tokens.Count; index++)
            {
                if (tokens[index].Text == "(") nesting++;
                else if (tokens[index].Text == ")") nesting--;
                else if (nesting == 0 && tokens[index].Text.Equals("and", StringComparison.OrdinalIgnoreCase)) { split = index; break; }
            }
            if (split < 0) throw new FormatException("Expected and between working-day endpoints");
            expression = new WorkdayCountExpression(Part(length + 1, split - length - 1), Part(split + 1, tokens.Count - split - 1));
            return true;
        }
        if (word is "since" or "until")
        {
            var date = Part(length + 1, tokens.Count - length - 1); var today = new DateAnchorExpression();
            expression = word == "since" ? new WorkdayCountExpression(date, today) : new WorkdayCountExpression(today, date); return true;
        }
        if (word == "in")
        {
            // A first-of-month literal gives strict month/year validation without reading the host clock.
            var monthTokens = new[] { new Token(TokenKind.Number, "1") }.Concat(tokens.Skip(length + 1)).ToArray();
            if (DateSyntax.TryLiteral(monthTokens, 0, out var first, out var consumed) && consumed == monthTokens.Length)
            {
                expression = new WorkdayCountExpression(new DateLiteralExpression(first), new DateLiteralExpression(new(first.Year, first.Month, DateTime.DaysInMonth(first.Year, first.Month))));
                return true;
            }
            if (length + 2 == tokens.Count && tokens[length + 1].Text.Length == 4 && int.TryParse(tokens[length + 1].Text, out var year) && year is >= 1 and <= 9999)
            { expression = new WorkdayCountExpression(new DateLiteralExpression(new(year, 1, 1)), new DateLiteralExpression(new(year, 12, 31))); return true; }
            throw new FormatException("Expected month and four-digit year, or year after working days in");
        }
        return false;
    }
}
