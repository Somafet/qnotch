namespace Calc.Core;

internal sealed record PlanningSentenceExpression(string Name,Expression[] Arguments,int AnnualScale=1,string Period="") : Expression;

internal sealed partial class ExpressionParser
{
    private readonly bool hasPlanningPhrases=tokens.Any(token=>token.Text.ToLowerInvariant() is "fire" or "depreciate" or "break" or "inflation");
    private bool TryPlanningSentence(out Expression expression)
    {
        expression=null!;
        if(tokens.Count<3 || knownNames?.Contains(string.Join(' ',tokens.Select(token=>token.Text)))==true) return false;
        Expression Part(int start,int end)
        {
            if(end<=start) throw new FormatException("Missing financial planning input");
            return new ExpressionParser(tokens.Skip(start).Take(end-start).ToArray(),cancellationToken,knownNames,questionDepth+1).Parse();
        }
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
        var first=tokens[0].Text.ToLowerInvariant();
        if(first is "fire" or "depreciate" or "break" && (KnownNameLength(0)>0 || tokens[1].Text=="(")) return false;
        if(first=="fire")
        {
            var at=Find("at",1); var end=at<0?tokens.Count:at;
            var period=tokens[end-1].Text.ToLowerInvariant();
            var scale=period switch {"month" or "monthly"=>12,"year" or "yearly" or "annually"=>1,_=>throw new FormatException("FIRE spending requires a monthly or yearly period")};
            var amountEnd=end-1;
            if(period is "month" or "year")
            {
                if(amountEnd<=1 || tokens[amountEnd-1].Text.ToLowerInvariant() is not "/" and not "per") throw new FormatException("Expected / or per before the spending period");
                amountEnd--;
            }
            var args=new List<Expression>{Part(1,amountEnd)};
            if(at>=0) args.Add(Part(at+1,tokens.Count));
            expression=new PlanningSentenceExpression("fire",args.ToArray(),scale,scale==12?"month":"year"); return true;
        }
        if(first=="depreciate")
        {
            var over=Find("over",1); if(over<0) throw new FormatException("Expected over before useful life");
            var salvage=Find("salvage",over+1); var end=salvage<0?tokens.Count:salvage;
            var period=tokens[end-1].Text.ToLowerInvariant();
            if(period is not "year" and not "years" and not "month" and not "months") throw new FormatException("Depreciation life requires months or years");
            expression=new PlanningSentenceExpression("sln",[Part(1,over),salvage<0?new LiteralExpression(default):Part(salvage+1,tokens.Count),Part(over+1,end-1)],Period:period.StartsWith("month",StringComparison.Ordinal)?"month":"year"); return true;
        }
        if(first=="break" && tokens[1].Text.Equals("even",StringComparison.OrdinalIgnoreCase))
        {
            if(!tokens[2].Text.Equals("fixed",StringComparison.OrdinalIgnoreCase)) throw new FormatException("Expected fixed cost");
            var price=Find(",",3); var cost=price<0?-1:Find(",",price+1);
            if(price<0 || cost<0 || price+1>=tokens.Count || cost+1>=tokens.Count || !tokens[price+1].Text.Equals("price",StringComparison.OrdinalIgnoreCase) || !tokens[cost+1].Text.Equals("cost",StringComparison.OrdinalIgnoreCase))
                throw new FormatException("Expected break even fixed amount, price amount, cost amount");
            expression=new CallExpression("breakeven",[Part(3,price),Part(price+2,cost),Part(cost+2,tokens.Count)]); return true;
        }
        if(tokens[^1].Text.Equals("inflation",StringComparison.OrdinalIgnoreCase))
        {
            var minus=Find("minus",1); if(minus<0) minus=Find("-",1);
            if(minus<0) return false;
            expression=new CallExpression("realreturn",[Part(0,minus),Part(minus+1,tokens.Count-1)]); return true;
        }
        return false;
    }
}
