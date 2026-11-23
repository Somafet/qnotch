namespace Calc.Core;

internal sealed record ChemistryExpression(string Formula, Expression? Amount = null, UnitExpression? Target = null) : Expression;
internal sealed record GradesExpression(Expression[] Scores, Expression[] Weights) : Expression;
internal sealed record EngineeringExpression(Expression Operand) : Expression;

internal sealed partial class ExpressionParser
{
    private string ChemicalFormula()
    {
        var start = position; var nesting = 0; var length = 0;
        while (position < tokens.Count)
        {
            var token = tokens[position];
            if (position > start && !token.JoinedToPrevious && token.Text != "·" && tokens[position - 1].Text != "·") break;
            if (token.Text == ")" && nesting == 0 || token.Text is "," or "+" or "-" or "*" or "/" or "^" or "%" or "!") break;
            if (token.Kind is not TokenKind.Name and not TokenKind.Number && token.Text is not "(" and not ")" and not "[" and not "]" and not "·") break;
            if (token.Text is "(" or "[") nesting++;
            if (token.Text is ")" or "]") nesting--;
            length += token.Text.Length; if (length > 512) throw new ArithmeticException("Chemical formula exceeds 512 characters");
            position++;
        }
        if (position == start) throw new FormatException("Expected a chemical formula literal");
        return string.Concat(tokens.Skip(start).Take(position - start).Select(token => token.Text));
    }
    private bool TryChemistryAtom(out Expression expression)
    {
        expression = null!;
        var key = Current.Text.ToLowerInvariant();
        var chemicalCall = key is "molarmass" or "moles" or "massof" && position + 1 < tokens.Count && tokens[position + 1].Text == "(";
        if (KnownNameLength(position) > 0 && !chemicalCall) return false;
        if (Current.Text.Equals("molar", StringComparison.OrdinalIgnoreCase) && position + 1 < tokens.Count && tokens[position + 1].Text.Equals("mass", StringComparison.OrdinalIgnoreCase))
        { position += 2; expression = new ChemistryExpression(ChemicalFormula()); return true; }
        if (key is not "molarmass" and not "moles" and not "massof" || position + 1 >= tokens.Count || tokens[position + 1].Text != "(") return false;
        position += 2;
        if (key == "molarmass") expression = new ChemistryExpression(ChemicalFormula());
        else
        {
            var input = Rounded(); if (!Take(",")) throw new FormatException("Chemical conversion expects quantity, formula literal");
            var formula = ChemicalFormula();
            expression = new ChemistryExpression(formula, input, UnitExpression.Single(UnitCatalog.ById(key == "moles" ? "mol" : "g")));
        }
        if (!Take(")")) throw new FormatException("Expected ) after chemical formula");
        return true;
    }
    private bool TryChemistrySuffix(ref Expression expression)
    {
        var grouped = Current.Text is "(" or "[";
        if (!grouped && (Current.Kind != TokenKind.Name || Current.Text[0] is < 'A' or > 'Z' || KnownNameLength(position) > 0)) return false;
        if (expression is LiteralExpression or ScaleExpression || !grouped && expression is not UnitExpressionNode && UnitCatalog.TryToken(Current.Text, out _)) return false;
        var saved = position; var formula = ChemicalFormula();
        if (!(Take("in") || TakeKeyword(KeywordRole.To)) || !UnitParser.TryParse(tokens, ref position, null, out var target)) { position = saved; return false; }
        if (target.Dimension != new Dimension(0, 1, 0, 0, 0, 0, 0, 0) && target.Dimension != new Dimension(0, 0, 0, 0, 0, 1, 0, 0)) { position = saved; return false; }
        expression = new ChemistryExpression(formula, expression, target); return true;
    }
    private bool TryGrades(out Expression expression)
    {
        expression = null!;
        if (!Current.Text.Equals("grades", StringComparison.OrdinalIgnoreCase) || KnownNameLength(position) > 0) return false;
        position++; var scores = new List<Expression>(); var weights = new List<Expression>();
        while (position < tokens.Count)
        {
            if (scores.Count == 128) throw new ArithmeticException("Grades exceed 128 natural-language pairs; use weightedMean lists");
            var end = position; var nesting = 0;
            while (end < tokens.Count)
            { if (nesting == 0 && tokens[end].Text == ",") break; if (tokens[end].Text is "(" or "[") nesting++; if (tokens[end].Text is ")" or "]") nesting--; end++; }
            var separator = -1; nesting = 0;
            for (var i = position; i < end; i++)
            {
                if (nesting == 0 && (tokens[i].Text.Equals("x", StringComparison.OrdinalIgnoreCase) || tokens[i].Kind == TokenKind.Name && tokens[i].Text.Length > 1 && tokens[i].Text[0] is 'x' or 'X' && tokens[i].Text[1..].All(char.IsAsciiDigit))) { separator = i; break; }
                if (tokens[i].Text is "(" or "[") nesting++; if (tokens[i].Text is ")" or "]") nesting--;
            }
            if (separator <= position) throw new FormatException("Grades require score x weight pairs");
            Expression Part(IEnumerable<Token> input) => new ExpressionParser(input.ToArray(), cancellationToken, knownNames, questionDepth + 1).Parse();
            scores.Add(Part(tokens.Skip(position).Take(separator - position)));
            var tail = tokens.Skip(separator + 1).Take(end - separator - 1);
            if (tokens[separator].Text.Length > 1) tail = new[] { new Token(TokenKind.Number, tokens[separator].Text[1..]) }.Concat(tail);
            weights.Add(Part(tail)); position = end;
            if (!Take(",")) break;
        }
        expression = new GradesExpression(scores.ToArray(), weights.ToArray()); return true;
    }
}
