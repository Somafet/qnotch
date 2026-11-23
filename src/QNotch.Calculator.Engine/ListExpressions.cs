namespace Calc.Core;

internal sealed record ListExpression(Expression[] Items) : Expression;

internal sealed partial class ExpressionParser
{
    private Expression ParseList()
    {
        var entries = new List<Expression>();
        if (!Take("]"))
        {
            do
            {
                if (entries.Count >= SheetList.MaxItems) throw new ArithmeticException("List exceeds 1024 values");
                if (DateSyntax.TryRecurringLiteral(tokens, position, out var month, out var day, out var length) &&
                    position + length < tokens.Count && tokens[position + length].Text is "," or "]")
                { position += length; entries.Add(new AnnualHolidayExpression(month, day)); }
                else entries.Add(Rounded());
            } while (Take(","));
            if (!Take("]")) throw new FormatException("Expected ] after list values");
        }
        return new ListExpression(entries.ToArray());
    }
}
