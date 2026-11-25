namespace Calc.Core;

internal enum HelperKind { Bmr, Tdee, HeartZones, Pace, RunTime, Race, Paint, Tiles, Concrete, FuelTrip, TimeDifference, Scale, Ingredient, Count }
/// <summary>One practical-helper sentence. Operands are evaluated first, in order; Words name the grammar options that were written.</summary>
internal sealed record HelperExpression(HelperKind Kind, Expression[] Operands, string[] Words, UnitExpression? Unit = null) : Expression;

internal sealed partial class ExpressionParser
{
    private static readonly HashSet<string> helperHeads = new(StringComparer.OrdinalIgnoreCase) { "bmr", "tdee", "hr", "pace", "race", "paint", "tiles", "concrete", "time", "scale" };
    private readonly bool hasAtWord = tokens.Any(token => token.Kind == TokenKind.Name && token.Text.Equals("at", StringComparison.OrdinalIgnoreCase));
    internal bool StartsHelper() { try { return TryHelper(out _) && position == tokens.Count; } catch (Exception error) when (error is FormatException or ArithmeticException) { return false; } }
    /// <summary>A helper sentence applies only when its complete grammar matches; otherwise the words keep their ordinary meaning as labels, prose or names.</summary>
    private bool TryHelper(out Expression expression)
    {
        expression = null!;
        if (position >= tokens.Count) return false;
        var head = Current.Kind == TokenKind.Name && helperHeads.Contains(Current.Text) && KnownNameLength(position) == 0;
        if (!head && !hasAtWord) return false;
        var end = position; var nesting = 0;
        for (; end < tokens.Count; end++)
        {
            var text = tokens[end].Text;
            if (nesting == 0 && text is ")" or "," or "]") break;
            if (text == "(") nesting++; else if (text == ")") nesting--;
        }
        if (end == position) return false;
        var segment = new ExpressionParser(tokens.Skip(position).Take(end - position).ToArray(), cancellationToken, knownNames, questionDepth + 1);
        Expression? sentence;
        try { sentence = head ? segment.HeadSentence() : segment.AtSentence(); if (sentence is not null) sentence = segment.RoundingTail(sentence); }
        catch (Exception error) when (error is FormatException or ArithmeticException) { return false; }
        if (sentence is null || segment.Current.Kind != TokenKind.End) return false;
        position = end; expression = sentence; return true;
    }
    private bool Word(string word)
    {
        if (Current.Kind != TokenKind.Name || !Current.Text.Equals(word, StringComparison.OrdinalIgnoreCase)) return false;
        position++; return true;
    }
    private Expression Slice(int start, int end) => new ExpressionParser(tokens.Skip(start).Take(end - start).ToArray(), cancellationToken, knownNames, questionDepth + 1).Parse();
    private int TopLevel(int start, Func<int, bool> match)
    {
        var nesting = 0;
        for (var index = start; index < tokens.Count; index++)
        {
            if (tokens[index].Text == "(") nesting++; else if (tokens[index].Text == ")") nesting--;
            else if (nesting == 0 && match(index)) return index;
        }
        return -1;
    }
    private Expression? HeadSentence()
    {
        var head = Current.Text.ToLowerInvariant(); position++;
        return head switch
        {
            "bmr" => BodySentence(HelperKind.Bmr), "tdee" => BodySentence(HelperKind.Tdee), "hr" => HeartZonesSentence(), "pace" => PaceSentence(), "race" => RaceSentence(),
            "paint" => PaintSentence(), "tiles" => TilesSentence(), "concrete" => ConcreteSentence(), "time" => TimeDifferenceSentence(), "scale" => ScaleSentence(), _ => null
        };
    }
    /// <summary>An existing variable or parameter, read as the operand it names.</summary>
    private Expression? NamedOperand()
    {
        var length = Current.Kind == TokenKind.Name ? KnownNameLength(position) : 0;
        if (length == 0) return null;
        var name = string.Join(' ', tokens.Skip(position).Take(length).Select(token => token.Text)); position += length;
        return new NameExpression(name);
    }
    /// <summary>A literal count, a variable or a parenthesized expression.</summary>
    private Expression? CountOperand()
    {
        if (Current.Kind == TokenKind.Number) return Number();
        if (NamedOperand() is { } named) return named;
        if (Current.Text != "(") return null;
        var start = position; position++; var inner = Rounded();
        if (Take(")")) return inner;
        position = start; return null;
    }
    /// <summary>A number with a unit (adjacent parts of one dimension add, as in 5 ft 11 in) or a parenthesized expression.</summary>
    private Expression? QuantityOperand()
    {
        if (Current.Kind == TokenKind.Name) return CountOperand();
        if (Current.Text == "(")
        {
            var group = CountOperand();   // a unit may follow the group: (20 + 7) min; "in" starts a conversion, not inches
            return group is not null && Current.Kind == TokenKind.Name && !Current.Text.Equals("in", StringComparison.OrdinalIgnoreCase) && UnitParser.TryParse(tokens, ref position, knownNames, out var groupUnit) ? new UnitExpressionNode(group, groupUnit, false) : group;
        }
        if (Current.Kind != TokenKind.Number) return null;
        var start = position; var amount = Number();
        if (!UnitParser.TryParse(tokens, ref position, knownNames, out var unit)) { position = start; return null; }
        Expression quantity = new UnitExpressionNode(amount, unit, false);
        while (Current.Kind == TokenKind.Number)
        {
            var part = position; var next = Number();
            if (!UnitParser.TryParse(tokens, ref position, knownNames, out var more) || more.Dimension != unit.Dimension) { position = part; break; }
            quantity = new BinaryExpression("+", quantity, new UnitExpressionNode(next, more, false));
        }
        return quantity;
    }
    private Expression? AgeOperand()
    {
        var age = CountOperand();
        if (age is not null && (Word("years") || Word("year") || Word("yrs") || Word("yr"))) { }
        return age;
    }
    private static UnitExpression Seconds => UnitExpression.Single(UnitCatalog.ById("s"));
    /// <summary>m:ss or h:mm:ss. The tokenizer reads these as clock literals; here they are durations.</summary>
    private Expression? ClockDuration()
    {
        if (Current.Kind != TokenKind.Time) return null;
        var parts = Current.Text.Split(':');
        if (parts.Length is < 2 or > 3 || parts.Any(part => part.Length == 0 || part[0] == '.')) return null;
        var last = parts[^1].Split('.');
        if (last.Length > 2 || last[0].Length != 2 || !parts[..^1].All(part => part.All(char.IsAsciiDigit)) || !last.All(part => part.All(char.IsAsciiDigit))) return null;
        var seconds = Rational.Parse(parts[^1]);
        var minutes = parts.Length == 3 ? Rational.Parse(parts[1]) : Rational.Parse(parts[0]);
        var hours = parts.Length == 3 ? Rational.Parse(parts[0]) : new Rational(0, 1);
        if (seconds.Numerator >= 60 * seconds.Denominator || parts.Length == 3 && (parts[1].Length != 2 || minutes.Numerator >= 60)) return null;
        position++;
        return new UnitExpressionNode(new LiteralExpression(hours * new Rational(3600, 1) + minutes * new Rational(60, 1) + seconds), Seconds, false);
    }
    private Expression? DurationOperand() => Current.Kind == TokenKind.Time ? ClockDuration() : QuantityOperand();
    private Expression? BodySentence(HelperKind kind)
    {
        var mass = QuantityOperand(); var height = mass is null ? null : QuantityOperand(); var age = height is null ? null : AgeOperand();
        if (age is null || Current.Kind != TokenKind.Name || Current.Text.ToLowerInvariant() is not ("male" or "female")) return null;
        var sex = Current.Text.ToLowerInvariant(); position++;
        if (kind == HelperKind.Bmr) return new HelperExpression(kind, [mass!, height!, age], [sex]);
        var level = Current.Kind == TokenKind.Name ? Current.Text.ToLowerInvariant() : "";
        if (level == "very" && position + 1 < tokens.Count && tokens[position + 1].Text.Equals("active", StringComparison.OrdinalIgnoreCase)) { position += 2; level = "very active"; }
        else if (level is "sedentary" or "light" or "moderate" or "active") position++;
        else return null;
        return new HelperExpression(kind, [mass!, height!, age], [sex, level]);
    }
    private Expression? HeartZonesSentence()
    {
        if (!Word("zones") && !Word("zone")) return null;
        var mode = Word("age") ? "age" : Word("max") ? "max" : "";
        if (mode == "") return null;
        var value = CountOperand();
        if (value is null) return null;
        if (mode == "age") _ = Word("years") || Word("year") || Word("yrs") || Word("yr"); else _ = Word("bpm");
        return new HelperExpression(HelperKind.HeartZones, [value], [mode]);
    }
    private Expression? PaceSentence()
    {
        var distance = QuantityOperand(); if (distance is null) return null;
        _ = Take("in");
        var time = DurationOperand();
        return time is null ? null : new HelperExpression(HelperKind.Pace, [distance, time], []);
    }
    private static Expression Kilometres(Expression amount) => new UnitExpressionNode(amount, UnitExpression.Single(UnitCatalog.ById("km")), false);
    private Expression? RaceSentence()
    {
        var distance = QuantityOperand(); if (distance is null) return null;
        _ = Take("in");
        var time = DurationOperand();
        if (time is null || !(Take("to") || TakeKeyword(KeywordRole.To)) || KnownNameLength(position) > 0) return null;
        Expression? target;
        if (Word("marathon")) target = Kilometres(new LiteralExpression(new(42195, 1000)));
        else if (Current.Text.Equals("half", StringComparison.OrdinalIgnoreCase) && (position + 1 < tokens.Count && tokens[position + 1].Text.Equals("marathon", StringComparison.OrdinalIgnoreCase) ||
            position + 2 < tokens.Count && tokens[position + 1].Text == "-" && tokens[position + 2].Text.Equals("marathon", StringComparison.OrdinalIgnoreCase)))
        { position += tokens[position + 1].Text == "-" ? 3 : 2; target = Kilometres(new LiteralExpression(new(210975, 10000))); }
        else if (Current.Kind == TokenKind.Number && position + 1 < tokens.Count && tokens[position + 1].Kind == TokenKind.Name && tokens[position + 1].JoinedToPrevious && tokens[position + 1].Text.Equals("k", StringComparison.OrdinalIgnoreCase))
        { target = Kilometres(new LiteralExpression(Rational.Parse(Current.Text))); position += 2; }
        else target = QuantityOperand();
        return target is null ? null : new HelperExpression(HelperKind.Race, [distance, time, target], []);
    }
    private Expression? PercentOperand()
    {
        var value = CountOperand();
        if (value is null) return null;
        if (Take("%") || Word("percent")) return new UnaryExpression("%", value);
        return value is NameExpression ? value : null;
    }
    private Expression? PaintSentence()
    {
        var area = QuantityOperand(); if (area is null) return null;
        var operands = new List<Expression> { area }; var words = new List<string>();
        if (Current.Kind == TokenKind.Number || Current.Text == "(" || KnownNameLength(position) > 0)
        {
            var coats = CountOperand();
            if (coats is null || !(Word("coats") || Word("coat"))) return null;
            operands.Add(coats); words.Add("coats");
        }
        if (Word("at")) { var rate = QuantityOperand(); if (rate is null) return null; operands.Add(rate); words.Add("rate"); }
        return new HelperExpression(HelperKind.Paint, operands.ToArray(), words.ToArray());
    }
    private Expression? TilesSentence()
    {
        var area = QuantityOperand(); if (area is null) return null;
        _ = Word("with") || Word("plus");
        if (Current.Kind != TokenKind.Number && Current.Text != "(" && KnownNameLength(position) == 0 && !Current.Text.Equals("waste", StringComparison.OrdinalIgnoreCase)) return new HelperExpression(HelperKind.Tiles, [area], []);
        Expression? waste;
        if (Word("waste")) waste = PercentOperand();
        else { waste = PercentOperand(); if (waste is null || !Word("waste")) return null; }
        return waste is null ? null : new HelperExpression(HelperKind.Tiles, [area, waste], ["waste"]);
    }
    private Expression? ConcreteSentence()
    {
        var volume = QuantityOperand(); if (volume is null) return null;
        var operands = new List<Expression> { volume }; var words = new List<string>();
        if (Current.Kind == TokenKind.Number || Current.Text == "(" || KnownNameLength(position) > 0)
        {
            var bag = QuantityOperand();
            if (bag is null || !(Word("bags") || Word("bag"))) return null;
            operands.Add(bag); words.Add("bag");
        }
        if (Word("at")) { var density = QuantityOperand(); if (density is null) return null; operands.Add(density); words.Add("density"); }
        return new HelperExpression(HelperKind.Concrete, operands.ToArray(), words.ToArray());
    }
    private Expression? TimeDifferenceSentence()
    {
        if (!Word("difference")) return null;
        _ = Word("from");
        if (KnownNameLength(position) > 0 || !TryZone(out var first, true) || !(Take("to") || TakeKeyword(KeywordRole.To)) || KnownNameLength(position) > 0 || !TryZone(out var second, true)) return null;
        if (Word("on"))
        {
            if (!DateSyntax.TryLiteral(tokens, position, out var date, out var length)) return null;
            position += length; return new HelperExpression(HelperKind.TimeDifference, [new DateLiteralExpression(date)], [first, second]);
        }
        return new HelperExpression(HelperKind.TimeDifference, [], [first, second]);
    }
    private Expression? ScaleSentence()
    {
        var from = TopLevel(position, index => tokens[index].Kind == TokenKind.Name && tokens[index].Text.Equals("from", StringComparison.OrdinalIgnoreCase));
        var to = from < 0 ? -1 : TopLevel(from + 1, index => KeywordCatalog.Match(tokens, index, KeywordRole.To) > 0);
        if (from <= position || to <= from + 1) return null;
        var last = tokens.Count; var tail = tokens[^1].Text.ToLowerInvariant();
        if (tail is "servings" or "serving" or "portions" or "portion" or "people") last--;
        if (last <= to + 1) return null;
        var result = new HelperExpression(HelperKind.Scale, [Slice(position, from), Slice(from + 1, to), Slice(to + 1, last)], []);
        position = tokens.Count; return result;
    }
    private static readonly Dimension TimePerLength = new(-1, 0, 1, 0, 0, 0, 0, 0);
    /// <summary>`5:30/km` or `5:30 per mi`: time per distance.</summary>
    private Expression? PaceLiteral()
    {
        var clock = ClockDuration();
        if (clock is null || !(Take("/") || Word("per")) || !UnitParser.TryParse(tokens, ref position, knownNames, out var unit) || unit.Dimension != new Dimension(1, 0, 0, 0, 0, 0, 0, 0)) return null;
        return new BinaryExpression("/", clock, new UnitExpressionNode(new LiteralExpression(new(1, 1)), unit, false));
    }
    /// <summary>`distance at pace` or `distance at consumption [at price]`; the right side must visibly be a pace or a fuel unit.</summary>
    private Expression? AtSentence()
    {
        var at = TopLevel(position, index => tokens[index].Kind == TokenKind.Name && tokens[index].Text.Equals("at", StringComparison.OrdinalIgnoreCase));
        if (at <= position || at + 1 >= tokens.Count) return null;
        var right = new ExpressionParser(tokens.Skip(at + 1).ToArray(), cancellationToken, knownNames, questionDepth + 1);
        var rate = right.Current.Kind == TokenKind.Time ? right.PaceLiteral() : right.QuantityOperand();
        var pace = rate is BinaryExpression { Operation: "/", Right: UnitExpressionNode } || rate is UnitExpressionNode { Conversion: false } quantity && quantity.Unit.Dimension == TimePerLength;
        var fuel = rate is UnitExpressionNode { Conversion: false } literal && literal.Unit.FuelForm() != 0;
        if (rate is null || !pace && !fuel) return null;
        var distance = Slice(position, at);
        position = at + 1 + right.position;
        if (pace) return new HelperExpression(HelperKind.RunTime, [distance, rate], []);
        if (!Word("at")) return new HelperExpression(HelperKind.FuelTrip, [distance, rate], []);
        var price = Slice(position, tokens.Count); position = tokens.Count;
        return new HelperExpression(HelperKind.FuelTrip, [distance, rate, price], ["price"]);
    }
    /// <summary>`1 cup flour in g`: an ingredient name between a measured quantity and its conversion target.</summary>
    private bool TryIngredientSuffix(ref Expression expression)
    {
        if (expression is LiteralExpression || Current.Kind != TokenKind.Name) return false;
        var start = position; _ = TakeKeyword(KeywordRole.Of);
        if (position >= tokens.Count || KnownNameLength(position) > 0) { position = start; return false; }
        bool Connective(int index, out int width)
        {
            width = tokens[index].Kind == TokenKind.Name && tokens[index].Text.Equals("in", StringComparison.OrdinalIgnoreCase) ? 1 : KeywordCatalog.Match(tokens, index, KeywordRole.To);
            return width > 0;
        }
        var known = IngredientCatalog.TryMatch(tokens, position, out var ingredient, out var length);
        var end = position + (known ? length : 0);
        if (!known) while (end < tokens.Count && end - position < 4 && tokens[end].Kind == TokenKind.Name && !Connective(end, out _)) end++;
        if (end == position || end >= tokens.Count || !Connective(end, out var width)) { position = start; return false; }
        var cursor = end + width;
        if (!UnitParser.TryParse(tokens, ref cursor, knownNames, out var target)) { position = start; return false; }
        if (known) { position = cursor; expression = new HelperExpression(HelperKind.Ingredient, [expression], [ingredient!.Id], target); return true; }
        // An unknown name is an error only when the sentence is otherwise a volume (or mass) quantity converted to the opposite dimension.
        var mass = new Dimension(0, 1, 0, 0, 0, 0, 0, 0); var volume = new Dimension(3, 0, 0, 0, 0, 0, 0, 0);
        if (expression is UnitExpressionNode { Conversion: false } measured && (measured.Unit.Dimension == volume && target.Dimension == mass || measured.Unit.Dimension == mass && target.Dimension == volume))
            throw new FormatException("Unknown ingredient: " + string.Join(' ', tokens.Skip(position).Take(end - position).Select(token => token.Text)));
        position = start; return false;
    }
    /// <summary>`3 sets`, `8 reps`: dimensionless counts, read only directly after a literal number and never over a user name.</summary>
    private bool TryCountSuffix(ref Expression expression)
    {
        if (expression is not LiteralExpression || Current.Kind != TokenKind.Name || Current.Text.ToLowerInvariant() is not ("set" or "sets" or "rep" or "reps") ||
            KnownNameLength(position) > 0 || position + 1 < tokens.Count && tokens[position + 1].Text == "(") return false;
        expression = new HelperExpression(HelperKind.Count, [expression], [Current.Text.ToLowerInvariant()]); position++; return true;
    }
}
