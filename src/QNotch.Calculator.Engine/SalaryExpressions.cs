namespace Calc.Core;

internal sealed record RomanianSalaryOptions(int? Dependants=null,int SchoolChildren=0,bool YouthRelief=false,
    bool MinimumRelief=true,bool MainJob=true,int? BasicSalary=null);
internal sealed record SalaryExpression(Expression Amount,bool Inverse,string? Country=null,int? Year=null,EarningsPeriod? OutputPeriod=null,
    DateOnly? PayrollDate=null,RomanianSalaryOptions? Romanian=null,bool EmployerCost=false) : Expression
{
    internal GermanSalaryOptions? German { get; init; }
    internal HungarianSalaryOptions? Hungarian { get; init; }
}

internal sealed partial class ExpressionParser
{
    private readonly bool hasSalaryPhrases=tokens.Any(token=>token.Text.ToLowerInvariant() is "gross" or "brut" or "brutto" or "net");
    private bool TrySalarySentence(out Expression expression)
    {
        expression=null!;
        if(tokens.Count<2 || knownNames?.Contains(string.Join(' ',tokens.Select(token=>token.Text)))==true) return false;
        var marker=-1; var nesting=0;
        for(var i=0;i<tokens.Count;i++)
        {
            cancellationToken.ThrowIfCancellationRequested(); var text=tokens[i].Text.ToLowerInvariant();
            if(text is "(" or "[") nesting++; else if(text is ")" or "]") nesting--;
            else if(i>0 && nesting==0 && KnownNameLength(i)==0 && text is "gross" or "brut" or "brutto" or "net") { marker=i; break; }
        }
        if(marker<0) return false;
        var inverse=tokens[marker].Text.Equals("net",StringComparison.OrdinalIgnoreCase); var tail=marker+1;
        if(inverse)
        {
            // Leave invoice 'date net N' to its own parser.
            if(tail+1>=tokens.Count || !tokens[tail].Text.Equals("in",StringComparison.OrdinalIgnoreCase) || tokens[tail+1].Text.ToLowerInvariant() is not "gross" and not "brut" and not "brutto") return false;
            tail+=2;
        }
        string? country=null; int? year=null; EarningsPeriod? period=null; DateOnly? payrollDate=null;
        RomanianSalaryOptions? ro=null; GermanSalaryOptions? de=null; HungarianSalaryOptions? hu=null; var employerCost=false;
        var optionsSeen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool TakeTail(string text)
        { if(tail<tokens.Count && tokens[tail].Text.Equals(text,StringComparison.OrdinalIgnoreCase)) { tail++; return true; } return false; }
        void Once(string name)
        { if(!optionsSeen.Add(name)) throw new FormatException("Duplicate salary option: "+name); }
        decimal Decimal(string what,decimal max,int places)
        {
            if(tail>=tokens.Count || !decimal.TryParse(tokens[tail].Text,System.Globalization.NumberStyles.AllowDecimalPoint,System.Globalization.CultureInfo.InvariantCulture,out var parsed) ||
                parsed>max || decimal.Round(parsed,places)!=parsed) throw new FormatException($"Expected {what}");
            tail++; return parsed;
        }
        while(tail<tokens.Count)
        {
            var word=tokens[tail++].Text.ToLowerInvariant();
            if(word=="for")
            {
                if(year is not null || payrollDate is not null || tail>=tokens.Count) throw new FormatException("Expected one salary tax year or payroll date");
                if(DateSyntax.TryLiteral(tokens,tail,out var date,out var dateLength)) { payrollDate=date; tail+=dateLength; }
                else
                {
                    if(tokens[tail].Text.Length!=4 || !int.TryParse(tokens[tail++].Text,out var parsedYear) || parsedYear<1) throw new FormatException("Expected a four-digit salary tax year or full payroll date");
                    year=parsedYear;
                }
            }
            else if(word is "in" or "to")
            {
                if(tail>=tokens.Count) throw new FormatException("Missing salary target or country");
                var target=tokens[tail++].Text;
                if(!inverse && target.Equals("net",StringComparison.OrdinalIgnoreCase)) continue;
                if(target.Equals("employer",StringComparison.OrdinalIgnoreCase) && TakeTail("cost"))
                { Once("employer cost"); employerCost=true; }
                else if(EarningsTarget(target,out var targetPeriod))
                { if(period is not null) throw new FormatException("Duplicate salary output period"); period=targetPeriod; }
                else
                {
                    if(country is not null || target.Length!=2 || !target.All(char.IsAsciiLetter)) throw new FormatException("Expected a two-letter salary country or earnings period");
                    country=target.ToUpperInvariant();
                }
            }
            else if(word=="as")
            {
                if(!TakeTail("pensioner")) throw new FormatException("Expected as pensioner");
                Once("pensioner"); hu=(hu??new()) with{Pensioner=true};
            }
            else if(word is "with" or "without" or "and")
            {
                if(word=="without")
                {
                    if(TakeTail("minimum") && TakeTail("relief")) { Once("minimum relief"); ro=(ro??new()) with{MinimumRelief=false}; }
                    else if(TakeTail("main") && TakeTail("job")) { Once("main job"); ro=(ro??new()) with{MainJob=false}; }
                    else if(TakeTail("childless") && TakeTail("surcharge")) { Once("childless surcharge"); de=(de??new()) with{ChildlessSurcharge=false}; }
                    else throw new FormatException("Expected without minimum relief, main job or childless surcharge");
                }
                else if(TakeTail("youth") && TakeTail("relief")) { Once("youth relief"); ro=(ro??new()) with{YouthRelief=true}; }
                else if(TakeTail("basic") && TakeTail("salary"))
                {
                    Once("basic salary");
                    if(tail>=tokens.Count || !int.TryParse(tokens[tail++].Text,out var basic) || basic<1 || basic>PayrollArithmetic.MaxAnnualGross) throw new FormatException("Expected a positive whole-leu basic salary");
                    ro=(ro??new()) with{BasicSalary=basic};
                }
                else if(TakeTail("tax") && TakeTail("class"))
                {
                    Once("tax class");
                    if(tail>=tokens.Count || !int.TryParse(tokens[tail++].Text,out var klass) || klass is < 1 or > 6) throw new FormatException("Expected German tax class 1 through 6");
                    de=(de??new()) with{TaxClass=klass};
                }
                else if(TakeTail("church") && TakeTail("tax"))
                {
                    Once("church tax"); var rate=9;
                    if(tail+1<tokens.Count && tokens[tail+1].Text=="%")
                    {
                        if(tokens[tail].Text is not "8" and not "9") throw new FormatException("Expected church tax 8% or 9%");
                        rate=tokens[tail].Text=="8"?8:9; tail+=2;
                    }
                    de=(de??new()) with{ChurchTaxPercent=rate};
                }
                else if(TakeTail("child") && TakeTail("allowance"))
                {
                    Once("child allowance"); var count=Decimal("a child allowance count in steps of 0.5 up to 20",20,1);
                    if(count*2!=decimal.Truncate(count*2)) throw new FormatException("Expected a child allowance count in steps of 0.5 up to 20");
                    de=(de??new()) with{ChildAllowances=count};
                }
                else if(TakeTail("health") && TakeTail("surcharge"))
                {
                    Once("health surcharge"); var rate=Decimal("a health surcharge percentage up to 10 with two decimals",10,2);
                    if(!TakeTail("%")) throw new FormatException("Expected % after the health surcharge");
                    de=(de??new()) with{HealthSurchargePercent=rate};
                }
                else if(TakeTail("Saxony")) { Once("Saxony"); de=(de??new()) with{Saxony=true}; }
                else if(TakeTail("átalányadó") || TakeTail("atalanyado") || TakeTail("átalányadózás") || TakeTail("atalanyadozas") || TakeTail("flat") && TakeTail("rate"))
                { Once("átalányadó"); hu=(hu??new()) with{FlatRate=true}; }
                else if(TakeTail("cost") && TakeTail("ratio"))
                {
                    Once("cost ratio");
                    if(tail+1>=tokens.Count || tokens[tail+1].Text!="%" || tokens[tail].Text is not "45" and not "80" and not "90") throw new FormatException("Expected átalányadó cost ratio 45%, 80% or 90%");
                    hu=(hu??new()) with{CostRatio=int.Parse(tokens[tail].Text,System.Globalization.CultureInfo.InvariantCulture)}; tail+=2;
                }
                else if(TakeTail("guaranteed") && TakeTail("minimum")) { Once("guaranteed minimum"); hu=(hu??new()) with{GuaranteedMinimum=true}; }
                else if((TakeTail("mothers") || TakeTail("mother")) && TakeTail("exemption")) { Once("mothers exemption"); hu=(hu??new()) with{MothersExemption=true}; }
                else if(TakeTail("first") && TakeTail("marriage")) { Once("first marriage"); hu=(hu??new()) with{FirstMarriage=true}; }
                else
                {
                    if(tail>=tokens.Count || !int.TryParse(tokens[tail++].Text,out var count) || count<0 || count>100) throw new FormatException("Expected a salary dependant/child count from 0 through 100");
                    if(TakeTail("dependant") || TakeTail("dependants") || TakeTail("dependent") || TakeTail("dependents"))
                    { Once("dependants"); ro=(ro??new()) with{Dependants=count}; }
                    else if(TakeTail("school") && (TakeTail("child") || TakeTail("children")))
                    { Once("school children"); ro=(ro??new()) with{SchoolChildren=count}; }
                    else if(TakeTail("child") || TakeTail("children"))
                    { Once("children"); de=(de??new()) with{Children=count}; }
                    else throw new FormatException("Expected dependants, school children or children");
                }
            }
            else throw new FormatException("Unexpected salary text; use amount gross/net in gross in a country, optionally for a tax year or payroll date");
        }
        var amount=new ExpressionParser(tokens.Take(marker).ToArray(),cancellationToken,knownNames,questionDepth+1).Parse();
        expression=new SalaryExpression(amount,inverse,country,year,period,payrollDate,ro,employerCost){German=de,Hungarian=hu}; return true;
    }
}
