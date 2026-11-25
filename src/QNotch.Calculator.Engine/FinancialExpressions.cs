namespace Calc.Core;

internal sealed record FinancialPlanExpression(string Kind, Expression Amount, Expression Rate, Expression Term, Expression? DownPayment = null, int Frequency = 1) : Expression { internal bool CompoundingSpecified { get; init; } }

internal sealed partial class ExpressionParser
{
    private bool TryFinancialSentence(out Expression expression)
    {
        expression = null!;
        if (tokens.Count < 5 || knownNames?.Contains(string.Join(' ', tokens.Select(token => token.Text))) == true) return false;
        var kind = tokens[0].Text.ToLowerInvariant();
        var prefixed = kind is "loan" or "mortgage" or "amortize" or "save";
        if (prefixed && (KnownNameLength(0) > 0 || tokens[1].Text == "(")) return false;
        int Find(string word, int start)
        {
            var nesting = 0;
            for (var i = 0; i < tokens.Count; i++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (tokens[i].Text is "(" or "[") nesting++;
                else if (tokens[i].Text is ")" or "]") nesting--;
                else if (i >= start && nesting == 0 && tokens[i].Text.Equals(word, StringComparison.OrdinalIgnoreCase)) return i;
            }
            return -1;
        }
        var at = Find("at", 1); var duration = at < 0 ? -1 : Find("for", at+1);
        if (at < 0 || duration < 0) return false;
        Expression Part(int start, int end)
        {
            if (end <= start) throw new FormatException("Missing financial input");
            return new ExpressionParser(tokens.Skip(start).Take(end-start).ToArray(), cancellationToken, knownNames, questionDepth+1).Parse();
        }
        var frequency = 1; var termEnd = tokens.Count; var amountEnd = at;
        var compounded = Find("compounded", duration+1);
        if (compounded >= 0)
        {
            if (prefixed && kind != "save" || compounded != tokens.Count-2) throw new FormatException("Expected compounded monthly or annually after the term");
            frequency = tokens[^1].Text.ToLowerInvariant() switch { "monthly" => 12, "annually" or "yearly" => 1, _ => throw new FormatException("Unsupported compounding frequency") };
            termEnd = compounded;
        }
        if (!prefixed) kind = "grow";
        Expression? down = null;
        var start = prefixed ? 1 : 0;
        if (kind is "mortgage" or "loan" or "amortize")
        {
            var with = Find("with", start);
            if (with >= 0 && with < at)
            {
                if (!tokens[at-1].Text.Equals("down", StringComparison.OrdinalIgnoreCase)) throw new FormatException("Expected down after the down payment");
                down = Part(with+1, at-1); amountEnd = with;
            }
        }
        if (kind == "save")
        {
            var unit = tokens[at-1].Text.ToLowerInvariant();
            var contributionFrequency = unit switch { "monthly" or "month" => 12, "yearly" or "annually" or "year" => 1, _ => throw new FormatException("Savings require monthly or yearly contributions") };
            amountEnd = at-1;
            if (unit is "month" or "year")
            {
                if (amountEnd <= start || tokens[amountEnd-1].Text.ToLowerInvariant() is not "/" and not "per") throw new FormatException("Expected / or per before the contribution period");
                amountEnd--;
            }
            if (compounded >= 0 && frequency != contributionFrequency) throw new ArithmeticException("Contribution and compounding periods must match");
            frequency = contributionFrequency;
        }
        expression = new FinancialPlanExpression(kind, Part(start, amountEnd), Part(at+1, duration), Part(duration+1, termEnd), down, frequency) { CompoundingSpecified=compounded>=0 };
        return true;
    }
}
