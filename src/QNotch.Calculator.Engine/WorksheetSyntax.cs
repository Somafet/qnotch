namespace Calc.Core;

internal sealed record PlotExpression(FormulaTerm Body, string Text, Expression[] Inputs, bool HasDomain) : Expression;
internal sealed record ChartExpression(ChartKind Kind, Expression? Data) : Expression { internal string? Tag { get; init; } }

/// <summary>plot formula [from a to b] and bar|pie|trend|line chart [of] [data]. Anything else is left to the ordinary parser, so prose and labels keep working.</summary>
internal static class WorksheetSyntax
{
    internal static Expression? TryParse(Token[] tokens, HashSet<string> names, CancellationToken token)
    {
        if (tokens.Length < 2 || tokens[0].Kind != TokenKind.Name || KnownPrefix(tokens, names)) return null;
        var head = tokens[0].Text.ToLowerInvariant();
        if (head == "plot") return Plot(tokens, names, token);
        if (!tokens[1].Text.Equals("chart", StringComparison.OrdinalIgnoreCase)) return null;
        return head switch { "bar" => Chart(ChartKind.Bar, tokens, names, token), "pie" => Chart(ChartKind.Pie, tokens, names, token), "trend" or "line" => Chart(ChartKind.Trend, tokens, names, token), _ => null };
    }
    private static bool KnownPrefix(Token[] tokens, HashSet<string> names)
    {
        var phrase = "";
        for (var i = 0; i < tokens.Length && tokens[i].Kind == TokenKind.Name && phrase.Length <= 128; i++)
        {
            phrase = i == 0 ? tokens[i].Text : phrase + " " + tokens[i].Text;
            if (names.Contains(phrase)) return true;
        }
        return false;
    }
    private static bool Known(string name, HashSet<string> names) => names.Contains(name) || name.Equals("prev", StringComparison.OrdinalIgnoreCase) || SheetSyntax.IsLineReference(name, out _);
    private static Expression? Operand(Token[] tokens, HashSet<string> names, CancellationToken token)
    {
        try { return new ExpressionParser(tokens, token, names).Parse(); }
        catch (FormatException) { return null; }
    }
    private static Expression? Plot(Token[] tokens, HashSet<string> names, CancellationToken token)
    {
        int from = -1, to = -1, nesting = 0;
        for (var i = 1; i < tokens.Length; i++)
        {
            token.ThrowIfCancellationRequested(); var word = tokens[i].Text;
            if (word == "(") nesting++; else if (word == ")") nesting--;
            else if (nesting == 0 && tokens[i].Kind == TokenKind.Name)
            {
                if (from < 0 && word.Equals("from", StringComparison.OrdinalIgnoreCase)) from = i;
                else if (from >= 0 && to < 0 && word.Equals("to", StringComparison.OrdinalIgnoreCase)) to = i;
            }
        }
        if (nesting != 0 || from >= 0 && (to <= from + 1 || to == tokens.Length - 1)) return null;
        var formula = tokens[1..(from < 0 ? tokens.Length : from)];
        var inputs = new List<Expression>(); FormulaTerm body;
        try { body = FormulaParser.Parse(formula, "x", inputs, new(StringComparer.OrdinalIgnoreCase), names, token); }
        catch (FormatException) { return null; }
        // "plot 5" stays a label and "plot twist" stays prose: a plot needs the variable, and every other word must be a sheet name.
        if (!FormulaFunctions.DependsOnVariable(body) || inputs.Any(input => !Known(((NameExpression)input).Name, names))) return null;
        if (from >= 0)
        {
            if (Operand(tokens[(from + 1)..to], names, token) is not { } lower || Operand(tokens[(to + 1)..], names, token) is not { } upper) return null;
            inputs.Add(lower); inputs.Add(upper);
        }
        var text = string.Concat(formula.Select((t, i) => (i == 0 || t.JoinedToPrevious ? "" : " ") + t.Text));
        return new PlotExpression(body, text, inputs.ToArray(), from >= 0);
    }
    private static Expression? Chart(ChartKind kind, Token[] tokens, HashSet<string> names, CancellationToken token)
    {
        var start = 2 + (tokens.Length > 2 && KeywordCatalog.IsOf(tokens[2].Text) ? 1 : 0);
        if (start == tokens.Length) return start == 2 ? new ChartExpression(kind, null) : null;
        // The rest is data only if it is a list, a known name or a call, so "bar chart monthly" and "bar chart 5" stay as they were.
        if (Operand(tokens[start..], names, token) is not { } data || data is not (ListExpression or NameExpression or CallExpression)) return null;
        return ExpressionEvaluation.Walk(data).OfType<NameExpression>().All(name => Known(name.Name, names)) ? new ChartExpression(kind, data) : null;
    }
    /// <summary>A chart label: the line's variable, its leading quoted or prose label, or its line reference.</summary>
    internal static string Label(ParsedLine line, string source, int index, CancellationToken token)
    {
        if (line.Assignment is { } name) return name;
        var quoted = source.TrimStart();
        if (quoted.StartsWith('"') && quoted.IndexOf('"', 1) is > 1 and var end) return quoted[1..end];
        Token[] tokens;
        try { tokens = ExpressionParser.Tokenize(line.Text, token); }
        catch (FormatException) { return "L" + (index + 1); }
        var words = tokens.TakeWhile(word => word.Kind == TokenKind.Name).ToArray();
        return words.Length > 0 && (words.Length == tokens.Length || tokens[words.Length].Text != "(") ? string.Join(' ', words.Select(word => word.Text)) : "L" + (index + 1);
    }
}
