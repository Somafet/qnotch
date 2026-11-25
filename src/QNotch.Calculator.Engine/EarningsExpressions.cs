namespace Calc.Core;

internal sealed record EarningsAttachExpression(Expression Operand,EarningsPeriod Period) : Expression;
internal sealed record EarningsConvertExpression(Expression Operand,EarningsPeriod Period) : Expression;
internal sealed record InvoiceDueExpression(Expression Date,Expression Days) : Expression;
internal sealed record LateFeeExpression(Expression Principal,Expression Rate,Expression Duration) : Expression;

internal sealed partial class ExpressionParser
{
    private readonly bool hasInvoicePhrases=tokens.Any(token=>token.Text.ToLowerInvariant() is "net" or "late");
    private static bool EarningsTarget(string text,out EarningsPeriod period)
    {
        period=text.ToLowerInvariant() switch {"hourly"=>EarningsPeriod.Hour,"daily"=>EarningsPeriod.Day,"monthly"=>EarningsPeriod.Month,"yearly" or "annually"=>EarningsPeriod.Year,_=>(EarningsPeriod)(-1)};
        return Enum.IsDefined(period);
    }
    private bool TryCalendarEarningsSuffix(ref Expression expression)
    {
        var saved=position;
        if(KnownNameLength(position)>0) return false;
        if(Take("/") || Take("per"))
        {
            var word=Current.Text.ToLowerInvariant();
            if(KnownNameLength(position)==0 && word is "month" or "year")
            { position++; expression=new EarningsAttachExpression(expression,word=="month"?EarningsPeriod.Month:EarningsPeriod.Year); return true; }
        }
        else if(Current.Text.ToLowerInvariant() is "monthly" or "yearly" or "annually")
        {
            EarningsTarget(Current.Text,out var period); position++; expression=new EarningsAttachExpression(expression,period); return true;
        }
        position=saved; return false;
    }
    private bool TryInvoiceSentence(out Expression expression)
    {
        expression=null!;
        if(tokens.Count<3 || knownNames?.Contains(string.Join(' ',tokens.Select(token=>token.Text)))==true) return false;
        Expression Part(int start,int end) => new ExpressionParser(tokens.Skip(start).Take(end-start).ToArray(),cancellationToken,knownNames,questionDepth+1).Parse();
        int Find(string word,int start)
        {
            var nesting=0;
            for(var i=0;i<tokens.Count;i++)
            {
                cancellationToken.ThrowIfCancellationRequested(); var text=tokens[i].Text;
                if(text is "(" or "[") nesting++; else if(text is ")" or "]") nesting--;
                else if(i>=start && nesting==0 && text.Equals(word,StringComparison.OrdinalIgnoreCase)) return i;
            }
            return -1;
        }
        if(tokens[0].Text.Equals("late",StringComparison.OrdinalIgnoreCase) && tokens[1].Text.Equals("fee",StringComparison.OrdinalIgnoreCase) && KnownNameLength(0)==0)
        {
            var at=Find("at",2); var forIndex=at<0?-1:Find("for",at+1);
            if(at<3 || forIndex<at+4 || forIndex>=tokens.Count-1 || tokens[forIndex-1].Text.ToLowerInvariant() is not "day" and not "days" || tokens[forIndex-2].Text.ToLowerInvariant() is not "/" and not "per")
                throw new FormatException("Expected late fee amount at rate/day for duration");
            expression=new LateFeeExpression(Part(2,at),Part(at+1,forIndex-2),Part(forIndex+1,tokens.Count)); return true;
        }
        var net=Find("net",1);
        if(net<1 || net>=tokens.Count-1 || tokens[net+1].Text.ToLowerInvariant() is "in" or "gross") return false;
        expression=new InvoiceDueExpression(Part(0,net),Part(net+1,tokens.Count)); return true;
    }
}
