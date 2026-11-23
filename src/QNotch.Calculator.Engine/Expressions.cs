namespace Calc.Core;

internal abstract record Expression;
internal sealed record LiteralExpression(Rational Value) : Expression;
internal sealed record NameExpression(string Name) : Expression;
internal sealed record UnaryExpression(string Operation, Expression Operand) : Expression;
internal sealed record BinaryExpression(string Operation, Expression Left, Expression Right) : Expression;
internal sealed record CallExpression(string Name, Expression[] Arguments) : Expression { internal int Site { get; init; } }
internal sealed record AggregateExpression(bool Average, string? Tag) : Expression;
internal enum RoundingKind { DecimalPlaces, Increment, SignificantFigures }
internal sealed record RoundingExpression(RoundingKind Kind, Expression Operand, Expression Precision) : Expression;
internal sealed record ScaleExpression(string Modifier, Rational Factor, Expression Operand) : Expression;
internal sealed record UnitExpressionNode(Expression Operand, UnitExpression Unit, bool Conversion) : Expression;
internal sealed record DateLiteralExpression(DateOnly Date) : Expression;
internal sealed record DateAnchorExpression(int Offset = 0, DayOfWeek? Weekday = null, int Direction = 1) : Expression;
internal sealed record CalendarPeriodExpression(Expression Count, int MonthsPerUnit) : Expression;
internal sealed record DateIntervalExpression(string Kind, Expression From, Expression To) : Expression;
internal sealed record DateShiftExpression(Expression Date, Expression Offset, int Direction) : Expression;
internal sealed record TimeLiteralExpression(ClockTime Time) : Expression;
internal sealed record TimeRangeExpression(Expression Start, Expression End) : Expression;

internal enum TokenKind { Colour, Codepoint, Aspect, Text, Ip, Integer, Number, Name, Symbol, Date, Time, Zone, Currency, End }
internal readonly record struct Token(TokenKind Kind, string Text, bool JoinedToPrevious = false);

internal sealed partial class ExpressionParser(IReadOnlyList<Token> tokens, CancellationToken cancellationToken, HashSet<string>? knownNames = null, int questionDepth = 0)
{
    private int position;
    private int depth;
    private readonly bool hasDatePhrases = tokens.Any(token => token.Kind == TokenKind.Name && token.Text.ToLowerInvariant() is "in" or "ago" or "days" or "weeks" or "age" or "workday" or "workdays" or "working" or "business");
    private Token Current => position < tokens.Count ? tokens[position] : new(TokenKind.End, "");
    internal Expression Parse()
    {
        if (questionDepth > 16) throw new ArithmeticException("Question depth limit exceeded");
        if (TryHelper(out var helperSentence)) return helperSentence;
        if (TryGrades(out var grades)) { if (Current.Kind != TokenKind.End) throw new FormatException("Unexpected text after grades"); return grades; }
        if(TrySalarySentence(out var salary)) return salary;
        if (TryInvoiceSentence(out var invoice)) return invoice;
        if (TryPlanningSentence(out var planning)) return planning;
        if (TryFinancialSentence(out var financial)) return financial;
        if (TryWorkdaySentence(out var workdays)) return workdays;
        if (TryDateSentence(out var dateSentence)) return dateSentence;
        if (TryRateForSentence(out var rateSentence)) return rateSentence;
        var isIndex = tokens.ToList().FindIndex(t => t.Kind == TokenKind.Name && t.Text.Equals("is", StringComparison.OrdinalIgnoreCase));
        if (isIndex > 0)
        {
            Expression Part(int start, int count) => new ExpressionParser(tokens.Skip(start).Take(count).ToArray(), cancellationToken, knownNames, questionDepth + 1).Parse();
            var tail = tokens.Skip(isIndex + 1).ToArray();
            if (tail.Length >= 4 && tail[0].Text.Equals("what", StringComparison.OrdinalIgnoreCase) && tail[1].Text == "%" && tail[2].Text.Equals("of", StringComparison.OrdinalIgnoreCase))
                return new CallExpression("share", [Part(0, isIndex), Part(isIndex + 4, tokens.Count - isIndex - 4)]);
            if (tail.Length >= 4 && tail[^1].Text.Equals("what", StringComparison.OrdinalIgnoreCase))
            {
                var operation = tail[^2].Text.ToLowerInvariant();
                if (operation is "of" or "off")
                    return new CallExpression(operation == "of" ? "whole" : "beforeDiscount", [Part(0, isIndex), Part(isIndex + 1, tokens.Count - isIndex - 3)]);
            }
        }
        var expression = Rounded();
        if (Current.Kind != TokenKind.End) throw new FormatException("Unexpected text");
        return expression;
    }
    internal Expression ParseAggregate(AggregateExpression aggregate, int prefixLength = 1)
    {
        position = prefixLength;
        var expression = RoundingTail(aggregate);
        if (Current.Kind != TokenKind.End) throw new FormatException("Unexpected text");
        return expression;
    }
    private Expression Rounded()
    {
        if (TryHelper(out var helperSentence)) return helperSentence;
        if (StartsCountdown()) return ParseCountdown();
        if (!hasDatePhrases && !hasPlanningPhrases && !hasInvoicePhrases && !hasSalaryPhrases && !hasRatePhrases && !tokens.Any(token => token.Text.Equals("at", StringComparison.OrdinalIgnoreCase))) return RoundingTail(BitOr());
        var end = position; var nesting = 0;
        for (; end < tokens.Count; end++)
        {
            var text = tokens[end].Text;
            if (nesting == 0 && text is ")" or "," or "]") break;
            if (text == "(") nesting++; else if (text == ")") nesting--;
        }
        if (end > position)
        {
            var segment = new ExpressionParser(tokens.Skip(position).Take(end - position).ToArray(), cancellationToken, knownNames, questionDepth);
            if (segment.TrySalarySentence(out var phrase) || segment.TryInvoiceSentence(out phrase) || segment.TryPlanningSentence(out phrase) || segment.TryFinancialSentence(out phrase) || segment.TryWorkdaySentence(out phrase) || segment.TryDateSentence(out phrase) || segment.TryRateForSentence(out phrase)) { position = end; return phrase; }
        }
        return RoundingTail(BitOr());
    }
    private Expression RoundingTail(Expression expression)
    {
        while (true)
        {
            var conversionPosition = position;
            if (Take("in") || TakeKeyword(KeywordRole.To))
            {
                if (TryUsageConversion(ref expression)) continue;
                if (TryNetworkConversion(ref expression, tokens[conversionPosition].Text.Equals("in", StringComparison.OrdinalIgnoreCase))) continue;
                if (Current.Text.ToLowerInvariant() is "rgb" or "hsl" or "ratio" or "aspect") { var helperTarget = Current.Text.ToLowerInvariant(); position++; expression = new CallExpression(helperTarget is "ratio" or "aspect" ? "asratio" : helperTarget, [expression]); continue; }
                if (TryIntegerConversion(ref expression)) continue;
                if (Current.Text.ToLowerInvariant() is "eng" or "engineering") { position++; expression = new EngineeringExpression(expression); continue; }
                if (Current.Text.ToLowerInvariant() is "colors" or "colours") { position++; expression = new CallExpression("resistorColors", [expression]); continue; }
                if(EarningsTarget(Current.Text,out var earningsTarget)) { position++; expression=new EarningsConvertExpression(expression,earningsTarget); continue; }
                if (TryCurrencyConversion(ref expression)) continue;
                if (Take("unix")) { expression = new UnixExpression(expression, true); continue; }
                var zoneStart = position;
                if (TryZone(out var zone, true))
                {
                    var unitEnd = zoneStart;
                    expression = UnitParser.TryParse(tokens, ref unitEnd, null, out var matchingUnit) && unitEnd == position ?
                        new UnitOrZoneExpression(expression, zone, matchingUnit, true) : new ZoneExpression(expression, zone, true);
                    continue;
                }
                if (UnitParser.TryParse(tokens, ref position, null, out var target))
                { expression = new UnitExpressionNode(expression, target, true); continue; }
                position = conversionPosition;
            }
            var to = TakeKeyword(KeywordRole.To);
            var leadingDecimal = TakeKeyword(KeywordRole.LeadingDecimals);
            var leadingSignificant = !leadingDecimal && TakeKeyword(KeywordRole.LeadingSignificant);
            if (!to && !leadingDecimal && !leadingSignificant) return expression;
            if (!leadingDecimal && !leadingSignificant && TakeKeyword(KeywordRole.Nearest))
                expression = new RoundingExpression(RoundingKind.Increment, expression, Unary());
            else
            {
                var precision = Unary();
                RoundingKind kind;
                if (leadingDecimal || leadingSignificant)
                {
                    if (!TakeKeyword(KeywordRole.Digits)) throw new FormatException("Expected precision digits");
                    kind = leadingDecimal ? RoundingKind.DecimalPlaces : RoundingKind.SignificantFigures;
                    _ = TakeKeyword(KeywordRole.RoundEnd);
                }
                else if (TakeKeyword(KeywordRole.Decimals)) kind = RoundingKind.DecimalPlaces;
                else if (TakeKeyword(KeywordRole.Significant)) kind = RoundingKind.SignificantFigures;
                else throw new FormatException("Expected decimals or sig figs");
                expression = new RoundingExpression(kind, expression, precision);
            }
        }
    }
    private bool TakeKeyword(KeywordRole role)
    {
        var length = KeywordCatalog.Match(tokens, position, role);
        position += length; return length != 0;
    }
    private bool Take(string text)
    {
        if (!Current.Text.Equals(text, StringComparison.OrdinalIgnoreCase)) return false;
        position++; return true;
    }
    private Expression Sum()
    {
        var expression = Range();
        while (Current.Text is "+" or "-")
        { var op = Current.Text; position++; expression = new BinaryExpression(op, expression, Range()); }
        return expression;
    }
    private Expression Range()
    {
        var expression = Parallel();
        while (Current.Text == "–" || Current.Text.Equals("to", StringComparison.OrdinalIgnoreCase) && position + 1 < tokens.Count && tokens[position + 1].Kind == TokenKind.Time)
        { position++; expression = new TimeRangeExpression(expression, Parallel()); }
        return expression;
    }
    private Expression Product()
    {
        var expression = Unary();
        while (true)
        {
            if (Current.Text is "*" or "/") { var op = Current.Text; position++; expression = new BinaryExpression(op, expression, Unary()); }
            else if (TakeKeyword(KeywordRole.Of)) expression = new BinaryExpression("of", expression, Unary());
            else return expression;
        }
    }
    private Expression Unary(bool allowTimestamp = true)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (++depth > 64) throw new ArithmeticException("Expression depth limit exceeded");
        try
        {
            if (Take("+")) return new UnaryExpression("+", Unary(allowTimestamp));
            if (Take("-")) return new UnaryExpression("-", Unary(allowTimestamp));
            if (Take("~")) return new UnaryExpression("~", Unary(allowTimestamp));
            var prefixDouble = KeywordCatalog.Match(tokens, position, KeywordRole.Double);
            var prefixHalf = KeywordCatalog.Match(tokens, position, KeywordRole.Half);
            var prefixLength = Math.Max(prefixDouble, prefixHalf);
            if (prefixLength > 0 && KnownNameLength(position) == 0 &&
                (position + prefixLength >= tokens.Count || tokens[position + prefixLength].Text != "("))
            {
                var modifier = string.Join(' ', tokens.Skip(position).Take(prefixLength).Select(token => token.Text)).ToLowerInvariant(); position += prefixLength;
                if (KnownNameLength(position) == 0) _ = TakeKeyword(KeywordRole.Of);
                return new ScaleExpression(modifier, prefixHalf > 0 ? new(1, 2) : new(2, 1), Unary(allowTimestamp));
            }
            var value = Postfix(allowTimestamp);
            if (Take("^")) value = new BinaryExpression("^", value, Unary(allowTimestamp));
            return value;
        }
        finally { depth--; }
    }
    private Expression Postfix(bool allowTimestamp = true)
    {
        var expression = Atom();
        while (true)
        {
            // A zone belongs to the complete date-at-clock join. In particular GB
            // is both an IANA zone and a data unit; do not attach it to the clock.
            if (!allowTimestamp)
            {
                var zoneStart = position; var isZone = TryZone(out _); position = zoneStart;
                if (isZone) return expression;
            }
            if (Current.Text is "%" or "!") { var op = Current.Text; position++; expression = new UnaryExpression(op, expression); }
            else if (allowTimestamp && TryTimestampTail(ref expression)) { }
            else if (TakeKeyword(KeywordRole.PostfixHalf)) expression = new ScaleExpression("half", new(1, 2), expression);
            else if (TakeKeyword(KeywordRole.PostfixDouble)) expression = new ScaleExpression("double", new(2, 1), expression);
            else if (TryIngredientSuffix(ref expression) || TryCountSuffix(ref expression)) { }
            else if (TryWorkdaySuffix(ref expression)) { }
            else if (TryCurrencySuffix(ref expression)) { }
            else if (TryUsageSuffix(ref expression)) { }
            else if (TryCalendarEarningsSuffix(ref expression)) { }
            else if (TryCalendarSuffix(ref expression)) CompositeTail(ref expression);
            else if (TryChemistrySuffix(ref expression)) { }
            else if (!StartsConversion() && UnitParser.TryParse(tokens, ref position, knownNames, out var unit))
            {
                expression = new UnitExpressionNode(expression, unit, false);
                CompositeTail(ref expression);
            }
            else return expression;
        }
    }
    private bool StartsConversion()
    {
        if (!Current.Text.Equals("in", StringComparison.OrdinalIgnoreCase)) return false;
        var saved = position; position++;
        var temporal = RateSyntax.TryKind(Current.Text,out _) || Current.Text == "(" || NetworkArithmetic.IsFunction(Current.Text) || Current.Text.Equals("cidr", StringComparison.OrdinalIgnoreCase) || Current.Text.Equals("mask", StringComparison.OrdinalIgnoreCase) || Current.Kind == TokenKind.Ip || KnownNameLength(position) > 0 || IntegerTarget() || Current.Text.ToLowerInvariant() is "rgb" or "hsl" or "ratio" or "aspect" or "colors" or "colours" or "eng" or "engineering" || EarningsTarget(Current.Text,out _) || Current.Text.Equals("unix", StringComparison.OrdinalIgnoreCase) || TryZone(out _, true) ||
            Current.Kind is TokenKind.Name or TokenKind.Currency && CurrencyCatalog.TryMatch(tokens,position,out _,out _);
        position = saved;
        if (temporal) return true;
        var next = position + 1;
        if (!UnitParser.TryParse(tokens, ref next, null, out _)) return false;
        return next == tokens.Count || tokens[next].Kind != TokenKind.Name || tokens[next].Text.Equals("in", StringComparison.OrdinalIgnoreCase) ||
            KeywordCatalog.Match(tokens, next, KeywordRole.To) > 0 || KeywordCatalog.Match(tokens, next, KeywordRole.LeadingDecimals) > 0 ||
            KeywordCatalog.Match(tokens, next, KeywordRole.LeadingSignificant) > 0;
    }
    private Expression Atom()
    {
        if (Current.Text.Equals("uuid", StringComparison.OrdinalIgnoreCase) && (KnownNameLength(position) == 0 || position + 1 < tokens.Count && tokens[position + 1].Text == "("))
        {
            var site = position++;
            if (Take("(") && !Take(")")) throw new FormatException("uuid expects no arguments");
            return new UuidExpression(site);
        }
        if (Current.Kind == TokenKind.Colour) { var literal = Current.Text; position++; return new ColourLiteralExpression(literal); }
        if (Current.Kind == TokenKind.Codepoint) { var literal = Current.Text; position++; return new CallExpression("codepoint", [new IntegerLiteralExpression("0x" + literal[2..])]); }
        if (Current.Kind == TokenKind.Aspect) { var dimensions = Current.Text.Split('x'); position++; return new CallExpression("aspect", dimensions.Select(v => (Expression)new LiteralExpression(Rational.Parse(v))).ToArray()); }
        if (Current.Kind == TokenKind.Text) { var quotedText = Current.Text; var literalIndex = 0; position++; return new TextLiteralExpression(TextSyntax.ReadQuoted(quotedText, ref literalIndex, cancellationToken)); }
        if (Take("/")) return ParsePrefixMask();
        if (Current.Kind == TokenKind.Ip) { var ip = Current.Text; position++; return new IpLiteralExpression(ip); }
        if (Current.Kind == TokenKind.Integer) { var literal = Current.Text; position++; return new IntegerLiteralExpression(literal); }
        if (TryChemistryAtom(out var chemistry)) return chemistry;
        if (TryResistorLiteral(out var resistor)) return resistor;
        if (TryCurrencyPrefix(out var money)) return money;
        if (Take("[")) return ParseList();
        if (Take("(")) { var value = Rounded(); if (!Take(")")) throw new FormatException("Expected )"); return value; }
        if (KnownNameLength(position) == 0 && (position + 1 >= tokens.Count || tokens[position + 1].Text != "("))
        {
            if (Take("now")) return new NowExpression();
            if (Take("unix")) return new UnixExpression(Unary(), false);
        }
        if (Current.Kind == TokenKind.Time)
        {
            var text = Current.Text; position++; string? meridiem = null;
            if (Current.Kind == TokenKind.Name && TimeSyntax.IsMeridiem(Current.Text)) { meridiem = Current.Text; position++; }
            return new TimeLiteralExpression(TimeSyntax.Parse(text, meridiem));
        }
        if (Current.Text.Equals("from", StringComparison.OrdinalIgnoreCase) && KnownNameLength(position) == 0 && (position + 1 >= tokens.Count || tokens[position + 1].Text != "("))
        {
            position++; var start = Product();
            if (!Take("to")) throw new FormatException("Expected to between clock endpoints");
            return new TimeRangeExpression(start, Product());
        }
        if (KnownNameLength(position) == 0 && DateSyntax.TryLiteral(tokens, position, out var date, out var dateLength))
        { position += dateLength; return new DateLiteralExpression(date); }
        if (TryCalendarEvent(out var calendarEvent)) return calendarEvent;
        if (TryDateAnchor(out var anchor)) return anchor;
        if (TryImaginaryLiteral(out var imaginary)) return imaginary;
        if (Current.Kind == TokenKind.Number)
            return Number();
        if (Current.Kind != TokenKind.Name) throw new FormatException("Expected expression");
        var callSite = position;
        var words = new List<string>(); var best = 0;
        var nameLength = 0;
        for (var end = position; end < tokens.Count && tokens[end].Kind == TokenKind.Name; end++)
        {
            nameLength += tokens[end].Text.Length + (end == position ? 0 : 1);
            if (nameLength > 128) break;
            words.Add(tokens[end].Text);
            if (knownNames?.Contains(string.Join(' ', words)) == true) best = words.Count;
        }
        words.Clear();
        if(best==0 && (Current.Text.Equals("prev",StringComparison.OrdinalIgnoreCase) || SheetSyntax.IsLineReference(Current.Text,out _))) best=1;
        if (best > 0)
        { for (var i = 0; i < best; i++) { words.Add(Current.Text); position++; } }
        else
        {
            words.Add(Current.Text); position++;
            var valueName = words[0] == "i" || ConstantCatalog.TryFind(words[0], out _);
            while (Current.Kind == TokenKind.Name && !KeywordCatalog.IsOf(Current.Text) && !Current.Text.Equals("xor", StringComparison.OrdinalIgnoreCase) && !(valueName && StartsValueTail()))
            { words.Add(Current.Text); position++; }
        }
        var name = string.Join(' ', words);
        if (name.Length > 128) throw new FormatException("Identifier limit exceeded");
        if (best == 0 && words.Count == 1 && Current.Text != "(" && name == "i") return new ImaginaryExpression(new(1, 1));
        if (best == 0 && words.Count == 1 && Current.Text != "(" && ConstantCatalog.TryFind(name, out _)) return new ConstantExpression(name);
        if (!Take("(")) return new NameExpression(name);
        if (best == 0 && CalculusSyntax.IsFunction(name)) return ParseCalculus(name);
        var args = new List<Expression>();
        if (!Take(")"))
        {
            do { args.Add(Rounded()); if (args.Count > 16) throw new ArithmeticException("Argument limit exceeded"); } while (Take(","));
            if (!Take(")")) throw new FormatException("Expected )");
        }
        return new CallExpression(name, args.ToArray()) { Site = callSite };
    }

    private int KnownNameLength(int start)
    {
        if (knownNames is null || knownNames.Count == 0) return 0;
        var callSite = position;
        var words = new List<string>(); var best = 0; var length = 0;
        for (var end = start; end < tokens.Count && tokens[end].Kind == TokenKind.Name; end++)
        {
            length += tokens[end].Text.Length + (end == start ? 0 : 1);
            if (length > 128) break;
            words.Add(tokens[end].Text);
            if (knownNames.Contains(string.Join(' ', words))) best = words.Count;
        }
        return best;
    }
    private Expression Number()
    {
        (Expression Node, Rational Coefficient, Rational Value, int CjkExponent) Group(bool cjkOnly)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var coefficient = Rational.Parse(Current.Text); position++;
            Expression node = new LiteralExpression(coefficient); var value = coefficient; var exponent = 0;
            if (Current.Kind == TokenKind.Name && NumberLanguage.TryMultiplier(Current.Text, Current.JoinedToPrevious, out var factor))
            {
                exponent = NumberLanguage.CjkExponent(Current.Text);
                if (cjkOnly && exponent == 0) throw new FormatException("Use descending CJK groups");
                node = new ScaleExpression(Current.Text, factor, node); value *= factor; position++;
            }
            return (node, coefficient, value, exponent);
        }
        var group = Group(false); var expression = group.Node;
        while (group.CjkExponent > 0 && Current.Kind == TokenKind.Number && Current.JoinedToPrevious)
        {
            if (group.Coefficient.Denominator != 1) throw new FormatException("Only the final CJK group can be fractional");
            var next = Group(true);
            var upper = System.Numerics.BigInteger.Pow(10, group.CjkExponent);
            if (next.CjkExponent >= group.CjkExponent || next.Value.Numerator >= upper * next.Value.Denominator)
                throw new FormatException("Use descending CJK groups");
            expression = new BinaryExpression("+", expression, next.Node); group = next;
        }
        return expression;
    }

    internal static Token[] Tokenize(string source, CancellationToken cancellationToken, HashSet<string>? knownNames = null)
    {
        source = TextSyntax.NormalizeNatural(source, cancellationToken);
        Stack<bool>? dataCalls = source.Contains('"') ? new() : null;
        var tokens = new List<Token>();
        var lastEnd = -1;
        for (var i = 0; i < source.Length;)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (tokens.Count >= 4096) throw new ArithmeticException("Expression token limit exceeded");
            if (char.IsWhiteSpace(source[i])) { i++; continue; }
            var start = i;
            var joined = start == lastEnd;
            if (source[i] == '"')
            {
                if (dataCalls is not null && dataCalls.TryPeek(out var data) && data)
                { var value = TextSyntax.ReadQuoted(source, ref i, cancellationToken); tokens.Add(new(TokenKind.Text, TextValue.Quote(value), joined)); }
                else
                {
                    i++; var closed = false;
                    while (i < source.Length) { if (source[i] == '\\') { i += 2; continue; } if (source[i++] == '"') { closed = true; break; } }
                    if (!closed) throw new FormatException("Unclosed quoted comment");
                }
            }
            else if (DeveloperSyntax.ColourLiteralLength(source, i) is var colourLength && colourLength > 0)
            { i += colourLength; tokens.Add(new(TokenKind.Colour, source[start..i], joined)); }
            else if (knownNames?.Contains("U") != true && DeveloperSyntax.CodepointLength(source, i) is var cpLength && cpLength > 0)
            { i += cpLength; tokens.Add(new(TokenKind.Codepoint, source[start..i], joined)); }
            else if (DeveloperSyntax.TryAspect(source, i, out var aspectEnd, out var dimensions))
            { i = aspectEnd; tokens.Add(new(TokenKind.Aspect, dimensions, joined)); }
            else if (IpLiteralLength(source, i) is var ipLength && ipLength > 0)
            { i += ipLength; tokens.Add(new(TokenKind.Ip, source[start..i], joined)); }
            else if (source[i] == '0' && i + 1 < source.Length && source[i + 1] is 'x' or 'X' or 'b' or 'B' or 'o' or 'O')
            {
                i += 2; while (i < source.Length && (char.IsLetterOrDigit(source[i]) || source[i] == '_')) i++;
                if (i - start > 8194) throw new ArithmeticException("Integer literal length limit exceeded");
                tokens.Add(new(TokenKind.Integer, source[start..i], joined));
            }
            else if (source[i] == 'T' && joined && tokens.Count > 0 && tokens[^1].Kind == TokenKind.Date && TimeSyntax.LiteralLength(source, i + 1) > 0)
            { i++; tokens.Add(new(TokenKind.Symbol, "T", true)); }
            else if (TimeSyntax.LiteralLength(source, i) is var timeLength && timeLength > 0)
            {
                i += timeLength; tokens.Add(new(TokenKind.Time, source[start..i], joined));
            }
            else if (DateSyntax.IsoLength(source, i) is var dateLength && dateLength > 0)
            {
                i += dateLength; tokens.Add(new(TokenKind.Date, source[start..i], joined));
            }
            else if (char.IsAsciiDigit(source[i]) || source[i] == '.')
            {
                while (i < source.Length && (char.IsAsciiDigit(source[i]) || source[i] == '.')) i++;
                var value = source[start..i];
                if (value.Length > 256 || value.Count(c => c == '.') > 1 || !value.Any(char.IsAsciiDigit)) throw new FormatException("Invalid number");
                tokens.Add(new(TokenKind.Number, value, joined));
            }
            else if (NumberLanguage.IsCjkScale(source[i]) && tokens.Count > 0 && tokens[^1].Kind == TokenKind.Number)
                tokens.Add(new(TokenKind.Name, source[i++].ToString(), joined));
            else if (source[i] == '°' && UnitCatalog.SymbolLength(source, i) is var symbolLength && symbolLength > 0)
            {
                i += symbolLength; tokens.Add(new(TokenKind.Name, source[start..i], joined));
            }
            else if ((char.GetUnicodeCategory(source[i]) == System.Globalization.UnicodeCategory.CurrencySymbol ||
                      char.IsLetter(source[i]) && (i + 1 < source.Length && source[i + 1] == '$' || i + 2 < source.Length && source[i + 2] == '$')) && CurrencyCatalog.SymbolLength(source,i) is var currencyLength && currencyLength > 0)
            { i += currencyLength; tokens.Add(new(TokenKind.Currency,source[start..i],joined)); }
            else if (char.IsLetter(source[i]) || source[i] == '_')
            {
                var zoneLength = ZoneCatalog.IdLength(source, i);
                if (zoneLength > 0) { i += zoneLength; tokens.Add(new(TokenKind.Zone, source[start..i], joined)); lastEnd = i; continue; }
                var keywordLength = KeywordCatalog.CjkTokenLength(source, i, knownNames);
                if (keywordLength > 0) i += keywordLength;
                else while (i < source.Length && (char.IsLetterOrDigit(source[i]) || source[i] is '_' or '²' or '³' || source[i] is >= '₀' and <= '₉' || KeywordCatalog.IsMark(source[i]))) i++;
                if (i - start > 128) throw new FormatException("Identifier limit exceeded");
                tokens.Add(new(TokenKind.Name, source[start..i], joined));
            }
            else
            {
                if (source[i] is '–' or '—') { i++; tokens.Add(new(TokenKind.Symbol, "–", joined)); lastEnd = i; continue; }
                if (source[i] == '|' && i + 1 < source.Length && source[i + 1] == '|') { i += 2; tokens.Add(new(TokenKind.Symbol, "||", joined)); lastEnd = i; continue; }
                if (source[i] is '<' or '>' && i + 1 < source.Length && source[i + 1] == source[i])
                {
                    i += 2; if (source[start] == '>' && i < source.Length && source[i] == '>') i++;
                    tokens.Add(new(TokenKind.Symbol, source[start..i], joined)); lastEnd = i; continue;
                }
                if (!"+-*/^!%(),[]·&|~".Contains(source[i])) throw new FormatException("Unexpected character");
                if (source[i] == '(' && dataCalls is not null) dataCalls.Push(dataCalls.TryPeek(out var inherited) && inherited || TextSyntax.DataCallAt(source, i));
                else if (source[i] == ')' && dataCalls is not null && dataCalls.Count > 0) dataCalls.Pop();
                tokens.Add(new(TokenKind.Symbol, source[i++].ToString(), joined));
            }
            lastEnd = i;
        }
        return tokens.ToArray();
    }
}
