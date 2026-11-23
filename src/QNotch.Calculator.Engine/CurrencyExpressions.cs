namespace Calc.Core;

internal sealed record CurrencyAttachExpression(Expression Operand,string Currency) : Expression;
internal sealed record CurrencyConvertExpression(Expression Operand,string Currency,UnitExpression? Unit = null,Expression? Date = null) : Expression;

internal sealed partial class ExpressionParser
{
    private bool TryCurrencySuffix(ref Expression expression)
    {
        if (Current.Kind is not TokenKind.Name and not TokenKind.Currency || KnownNameLength(position) > 0 ||
            !CurrencyCatalog.TryMatch(tokens,position,out var currency,out var length)) return false;
        position += length; expression = new CurrencyAttachExpression(expression,currency.Code); return true;
    }
    private bool TryCurrencyPrefix(out Expression expression)
    {
        expression = null!;
        if (Current.Kind is not TokenKind.Name and not TokenKind.Currency || KnownNameLength(position) > 0 ||
            !CurrencyCatalog.TryMatch(tokens,position,out var currency,out var length)) return false;
        var next = position + length;
        if (next < tokens.Count && tokens[next].Text == "(" && length == 1 && FunctionLibrary.IsBuiltin(Current.Text)) return false;
        if (next >= tokens.Count || tokens[next].Kind != TokenKind.Number && tokens[next].Text is not "(" and not "+" and not "-") return false;
        position = next; var operand=Unary();
        expression = operand is UsagePriceExpression price ? price with { Operand=new CurrencyAttachExpression(price.Operand,currency.Code) } : new CurrencyAttachExpression(operand,currency.Code); return true;
    }
    private bool TryCurrencyConversion(ref Expression expression)
    {
        if (Current.Kind is not TokenKind.Name and not TokenKind.Currency || !CurrencyCatalog.TryMatch(tokens,position,out var currency,out var length)) return false;
        position += length;
        UnitExpression? unit = null;
        if (!StartsConversion() && UnitParser.TryParse(tokens,ref position,knownNames,out var parsed)) unit = parsed;
        Expression? date = null;
        if (Take("on"))
        {
            var end = position; var nesting = 0;
            for (; end < tokens.Count; end++)
            {
                var text = tokens[end].Text;
                if (nesting == 0 && text is "," or ")" or "]") break;
                if (text is "(" or "[") nesting++; else if (text is ")" or "]") nesting--;
            }
            date = new ExpressionParser(tokens.Skip(position).Take(end-position).ToArray(),cancellationToken,knownNames,questionDepth+1).Parse();
            position = end;
        }
        expression = new CurrencyConvertExpression(expression,currency.Code,unit,date); return true;
    }
}
