namespace Calc.Core;

internal sealed record UsageCountExpression(Expression Operand,UsageKind Kind):Expression;
internal sealed record UsagePriceExpression(Expression Operand,Rational PerCount,UsageKind? Kind):Expression;
internal sealed record UsageConvertExpression(Expression Operand,UsageKind Kind,UnitExpression? Unit):Expression;
internal sealed record RateForExpression(Expression Rate,Expression Duration):Expression;

internal static class RateSyntax
{
    internal static bool TryKind(string text,out UsageKind kind)
    {
        kind=text.ToLowerInvariant() switch{"token" or "tokens"=>UsageKind.Tokens,"request" or "requests" or "req"=>UsageKind.Requests,"item" or "items"=>UsageKind.Items,_=>(UsageKind)(-1)};
        return Enum.IsDefined(kind);
    }
    internal static bool TrySpeedUnit(string text,out UnitExpression unit)
    {
        unit=null!;if(text.Length is <3 or >7||!text.EndsWith("ps",StringComparison.Ordinal))return false;
        var prefix=text[..^2];var suffix=prefix[^1];if(suffix is not ('b' or 'B'))return false;
        var scale=prefix[..^1];if(scale is not ("" or "k" or "M" or "G" or "T" or "P" or "E" or "Ki" or "Mi" or "Gi" or "Ti" or "Pi" or "Ei"))return false;
        var id=suffix=='b'?scale+"bit":scale+"B";
        unit=UnitExpression.Single(UnitCatalog.ById(id)).Combine(UnitExpression.Single(UnitCatalog.ById("s")),-1);return true;
    }
}

internal sealed partial class ExpressionParser
{
    private readonly bool hasRatePhrases=tokens.Any(t=>t.Kind==TokenKind.Name&&t.Text.ToLowerInvariant() is "for" or "uptime");
    private bool TryUsageConversion(ref Expression expression)
    {
        if(!RateSyntax.TryKind(Current.Text,out var kind))return false;
        position++;UnitExpression? unit=null;
        if(UnitParser.TryParse(tokens,ref position,null,out var parsed))unit=parsed;
        expression=new UsageConvertExpression(expression,kind,unit);return true;
    }
    private bool TryUsageSuffix(ref Expression expression)
    {
        if(KnownNameLength(position)>0)return false;
        if(RateSyntax.TryKind(Current.Text,out var kind)&&!(position+1<tokens.Count&&tokens[position+1].Text=="("))
        {position++;expression=new UsageCountExpression(expression,kind);return true;}
        if(Current.Text.Equals("uptime",StringComparison.OrdinalIgnoreCase))
        {position++;expression=new CallExpression("uptime",[expression]);return true;}
        if(Current.Text is "/" || Current.Text.Equals("per",StringComparison.OrdinalIgnoreCase))
        {
            var saved=position;position++;
            if(Current.Text=="M"&&KnownNameLength(position)==0)
            {
                position++;UsageKind? priceKind=null;
                if(KnownNameLength(position)==0&&RateSyntax.TryKind(Current.Text,out var explicitKind)){priceKind=explicitKind;position++;}
                expression=new UsagePriceExpression(expression,new(1_000_000,1),priceKind);return true;
            }
            position=saved;
        }
        return false;
    }
    private bool TryRateForSentence(out Expression expression)
    {
        expression=null!;if(tokens.Count<3||knownNames?.Contains(string.Join(' ',tokens.Select(t=>t.Text)))==true)return false;
        var nesting=0;var split=-1;var uptime=-1;
        for(var i=0;i<tokens.Count;i++)
        {
            cancellationToken.ThrowIfCancellationRequested();var text=tokens[i].Text;
            if(text is "(" or "[")nesting++;else if(text is ")" or "]")nesting--;
            else if(nesting==0&&text.Equals("for",StringComparison.OrdinalIgnoreCase)){split=i;break;}
            else if(nesting==0&&text.Equals("uptime",StringComparison.OrdinalIgnoreCase))uptime=i;
        }
        if(split<1||split==tokens.Count-1)return false;
        Expression Part(int start,int end)=>new ExpressionParser(tokens.Skip(start).Take(end-start).ToArray(),cancellationToken,knownNames,questionDepth+1).Parse();
        if(uptime>0&&uptime==split-1)expression=new CallExpression("downtime",[Part(0,uptime),Part(split+1,tokens.Count)]);
        else expression=new RateForExpression(Part(0,split),Part(split+1,tokens.Count));
        return true;
    }
}
