using System.Text;

namespace Calc.Core;

internal sealed record ParsedLine(string Text, string? Assignment, string[] Tags, bool Boundary, Expression? Expression, string? Error)
{
    internal FunctionDirective? Directive { get; init; }
    internal string? FunctionName { get; init; }
}

internal static class SheetSyntax
{
    internal static string NormalizeName(string name) => string.Join(' ', name.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    internal static bool IsReserved(string name) => name.Equals("prev", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("sum", StringComparison.OrdinalIgnoreCase) || name.Equals("average", StringComparison.OrdinalIgnoreCase) || IsLineReference(name, out _);
    internal static bool ValidName(string name) => name.Length is > 0 and <= 128 && !IsReserved(name) && name.Split(' ').All(w =>
        (char.IsLetter(w[0]) || w[0] == '_') && w.All(c => char.IsLetterOrDigit(c) || c == '_' || KeywordCatalog.IsMark(c)));
    internal static bool IsLineReference(string name, out int index)
    {
        index = -1;
        if (name.Length < 2 || char.ToUpperInvariant(name[0]) != 'L' || !name[1..].All(char.IsAsciiDigit)) return false;
        if (!int.TryParse(name.AsSpan(1), out var number)) return true;
        index = number - 1; return true;
    }
    internal static ParsedLine Scan(string line, CancellationToken cancellationToken = default)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed.StartsWith("# ") || trimmed == "#") return new("", null, [], true, null, null);
        try { line = TextSyntax.NormalizeNatural(line, cancellationToken); }
        catch (Exception e) when (e is FormatException or ArithmeticException) { return new("", null, [], false, null, e.Message) { FunctionName = TextSyntax.AttemptedDefinitionName(line) }; }
        Stack<bool>? dataCalls = line.Contains('"') ? new() : null;
        var text = new StringBuilder(); var tags = new List<string>();
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            if ((i & 255) == 0) cancellationToken.ThrowIfCancellationRequested();
            var c = line[i];
            if (!quoted && c == '"' && dataCalls is not null && dataCalls.TryPeek(out var data) && data)
            {
                var end = i; try { _ = TextSyntax.ReadQuoted(line, ref end, cancellationToken); }
                catch (Exception e) when (e is FormatException or ArithmeticException) { return new("", null, [], false, null, e.Message) { FunctionName = TextSyntax.AttemptedDefinitionName(line) }; }
                text.Append(line.AsSpan(i, end - i)); i = end - 1; continue;
            }
            if (quoted && c == '\\' && i + 1 < line.Length) { i++; continue; }
            if (c == '"') { quoted = !quoted; text.Append(' '); continue; }
            if (quoted) continue;
            if (c == '(' && dataCalls is not null) dataCalls.Push(dataCalls.TryPeek(out var inherited) && inherited || TextSyntax.DataCallAt(line, i));
            else if (c == ')' && dataCalls is not null && dataCalls.Count > 0) dataCalls.Pop();
            if (c == '/' && i + 1 < line.Length && line[i + 1] == '/') break;
            if (c == '#' && DeveloperSyntax.ColourLiteralLength(line, i) is var colourLength && colourLength > 0) { text.Append(line.AsSpan(i, colourLength)); i += colourLength - 1; continue; }
            if (c == '#')
            {
                var start = ++i;
                while (i < line.Length && (char.IsLetterOrDigit(line[i]) || line[i] is '_' or '-' || KeywordCatalog.IsMark(line[i]))) i++;
                if (start == i || i - start > 64) return new("", null, [], false, null, "Invalid tag");
                tags.Add(line[start..i]); text.Append(' '); i--; continue;
            }
            text.Append(c);
        }
        if (quoted) return new("", null, tags.ToArray(), false, null, "Unclosed quoted comment");
        var source = text.ToString().Trim();
        if (source.StartsWith("forget ", StringComparison.OrdinalIgnoreCase))
        {
            var name = source[7..].Trim();
            if (!FunctionLibrary.ValidIdentifier(name, 64) || FunctionLibrary.IsBuiltin(name)) return new(source, null, [], false, null, "Invalid function name");
            return new(source, null, [], false, null, null) { Directive = new(FunctionLibrary.Hash("FORGET " + name.ToUpperInvariant()), null, name), FunctionName = name };
        }
        var equal = TextSyntax.AssignmentIndex(source); string? assignment = null;
        // "solve left = right" is an equation, not an assignment or definition; Parse re-checks for a user variable named solve.
        if (equal >= 0 && EquationSyntax.Prefix(source)) return new(source, null, tags.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), false, null, null);
        if (equal >= 0 && source[..equal].Contains('('))
        {
            var open = source.IndexOf('('); var name = source[..open].Trim();
            try
            {
                var header = source[..equal].Trim();
                if (!FunctionLibrary.ValidIdentifier(name, 64) || !header.EndsWith(')')) throw new FormatException("Invalid function signature");
                var parameterText = header[(open + 1)..^1];
                var parameters = parameterText.Trim().Length == 0 ? [] : parameterText.Split(',').Select(p => p.Trim()).ToArray();
                var definition = new FunctionDefinition(name, parameters, source[(equal + 1)..].Trim());
                var key = FunctionLibrary.Hash(FunctionLibrary.Canonical(definition));
                return new(source, null, [], false, null, null) { Directive = new(key, definition, name), FunctionName = name };
            }
            catch (Exception e) when (e is FormatException or ArithmeticException) { return new(source, null, [], false, null, e.Message) { FunctionName = name }; }
        }
        if (equal >= 0)
        {
            assignment = NormalizeName(source[..equal]); source = source[(equal + 1)..].Trim();
            if (!ValidName(assignment))
                return new(source, null, tags.ToArray(), false, null, "Invalid variable name");
        }
        return new(source, assignment, tags.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), false, null, null);
    }
    internal static ParsedLine Parse(ParsedLine line, HashSet<string> names, CancellationToken cancellationToken)
    {
        if (line.Error is not null || line.Boundary || line.Directive is not null || line.Expression is not null) return line;
        try
        {
            if (DiceSyntax.TryParse(line.Text, names) is { } dice) return line with { Expression = new DiceExpression(dice) };
            if (EquationSyntax.Prefix(line.Text) && !names.Contains("solve")) return line with { Expression = EquationSyntax.Parse(line.Text, names, cancellationToken) };
            var tokens = ExpressionParser.Tokenize(line.Text, cancellationToken, names);
            if (tokens.Length == 0)
                return line.Assignment is null ? line : line with { Error = "Expected expression" };
            if (WorksheetSyntax.TryParse(tokens, names, cancellationToken) is { } worksheet)
            {
                if (line.Tags.Length > 1) throw new FormatException("Use one tag filter per chart");
                return line with { Expression = worksheet is ChartExpression { Data: null } chart ? chart with { Tag = line.Tags.FirstOrDefault() } : worksheet };
            }
            var sumLength = KeywordCatalog.Match(tokens, 0, KeywordRole.Sum);
            var averageLength = KeywordCatalog.Match(tokens, 0, KeywordRole.Average);
            var aggregateLength = Math.Max(sumLength, averageLength);
            var aggregateName = string.Join(' ', tokens.Take(aggregateLength).Select(token => token.Text));
            if (aggregateLength > 0 && !names.Contains(aggregateName) &&
                (tokens.Length == aggregateLength || tokens[aggregateLength].Text.Equals("in", StringComparison.OrdinalIgnoreCase) || KeywordCatalog.Match(tokens, aggregateLength, KeywordRole.To) > 0 ||
                 KeywordCatalog.Match(tokens, aggregateLength, KeywordRole.LeadingDecimals) > 0 || KeywordCatalog.Match(tokens, aggregateLength, KeywordRole.LeadingSignificant) > 0))
            {
                if (line.Tags.Length > 1) throw new FormatException("Use one tag filter per aggregate");
                var aggregate = new AggregateExpression(averageLength > 0, line.Tags.FirstOrDefault());
                return line with { Expression = new ExpressionParser(tokens, cancellationToken, names).ParseAggregate(aggregate, aggregateLength) };
            }
            // Only a leading label directly followed by a number can be ignored. Known operands
            // and unknown words next to arithmetic operators are never silently discarded.
            var count = 0;
            while (count < tokens.Length && tokens[count].Kind == TokenKind.Name) count++;
            var knownPrefix = ConstantCatalog.IsRoundingLine(tokens);
            var prefix = new StringBuilder();
            for (var n = 0; n < count; n++)
            {
                if (n > 0) prefix.Append(' ');
                prefix.Append(tokens[n].Text);
                if (prefix.Length > 128) break;
                if (names.Contains(prefix.ToString()) || IsReserved(prefix.ToString())) { knownPrefix = true; break; }
            }
            var prefixLength = Math.Max(KeywordCatalog.Match(tokens, 0, KeywordRole.Double), KeywordCatalog.Match(tokens, 0, KeywordRole.Half));
            var conversational = !knownPrefix && prefixLength > 0 && tokens.Length > prefixLength && tokens[prefixLength].Text != "(";
            var datePhrase = DateSyntax.IsNaturalStart(tokens, names) || tokens[^1].Text.Equals("ago", StringComparison.OrdinalIgnoreCase);
            var startsDate = DateSyntax.TryLiteral(tokens, 0, out _, out _);
            var salaryPhrase=tokens.Skip(1).Any(token=>token.Text.ToLowerInvariant() is "gross" or "brut" or "brutto" or "net");
            var timePhrase = salaryPhrase || tokens[0].Text.ToLowerInvariant() is "uuid" or "from" or "now" or "unix" or "loan" or "mortgage" or "amortize" or "save" or "fire" or "depreciate" or "break" or "late";
            var moneyPhrase = tokens[0].Kind == TokenKind.Currency || line.Assignment is null && !knownPrefix && CurrencyCatalog.TryMatch(tokens,0,out _,out var currencyPrefix) && currencyPrefix < tokens.Length &&
                (tokens[currencyPrefix].Kind is TokenKind.Number or TokenKind.Integer || tokens[currencyPrefix].Text is "(" or "+" or "-");
            var practicalPhrase = !knownPrefix && (new ExpressionParser(tokens, cancellationToken, names).StartsHelper() || tokens[0].Text.Equals("grades", StringComparison.OrdinalIgnoreCase) || tokens.Length > 1 && tokens[0].Text.Equals("molar", StringComparison.OrdinalIgnoreCase) && tokens[1].Text.Equals("mass", StringComparison.OrdinalIgnoreCase));
            var resistorPhrase = !knownPrefix && count >= 3 && tokens.Take(3).All(token => ResistorColorCatalog.TryGet(token.Text, out _));
            if (line.Assignment is null && tokens.All(t => t.Kind == TokenKind.Name) && !names.Contains(NormalizeName(line.Text)) && !(tokens.Length == 1 && (tokens[0].Text.ToLowerInvariant() is "pi" or "π" || ConstantCatalog.IsLoneValue(tokens[0].Text))) && !ConstantCatalog.IsConversionLine(tokens) &&
                !IsReserved(NormalizeName(line.Text)) && !conversational && !datePhrase && !timePhrase && !resistorPhrase && !practicalPhrase && !(knownPrefix && Enumerable.Range(0, tokens.Length).Any(index =>
                    tokens[index].Text.ToLowerInvariant() is "at" or "for" or "uptime" || tokens[index].Text.Equals("in", StringComparison.OrdinalIgnoreCase) || tokens[index].Text.Equals("net",StringComparison.OrdinalIgnoreCase) || CurrencyCatalog.TryMatch(tokens, index, out _, out _) || KeywordCatalog.Match(tokens, index, KeywordRole.To) > 0 || KeywordCatalog.Match(tokens, index, KeywordRole.LeadingDecimals) > 0 || KeywordCatalog.Match(tokens, index, KeywordRole.LeadingSignificant) > 0))) return line;
            if (line.Assignment is null && count > 0 && count < tokens.Length && tokens[count].Kind is TokenKind.Ip or TokenKind.Integer or TokenKind.Number or TokenKind.Date or TokenKind.Time && !knownPrefix && !conversational && !datePhrase && !startsDate && !timePhrase && !moneyPhrase && !resistorPhrase && !practicalPhrase)
            {
                if (Enumerable.Range(0, count).Any(index => KeywordCatalog.Match(tokens, index, KeywordRole.Double) > 0 ||
                    KeywordCatalog.Match(tokens, index, KeywordRole.Half) > 0)) throw new FormatException("Quote labels before conversational expressions");
                tokens = tokens.Skip(count > 1 && DateSyntax.TryLiteral(tokens, count - 1, out _, out _) ? count - 1 : count).ToArray();
            }
            return line with { Expression = new ExpressionParser(tokens, cancellationToken, names).Parse() };
        }
        catch (Exception e) when (e is FormatException or ArithmeticException) { return line with { Error = e.Message }; }
    }
}
