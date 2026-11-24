namespace Calc.Core;

public sealed record RomanianTaxCharge(string Name,Rational Amount);
public sealed record RomanianTaxEvidence(string Model,int TaxYear,string RuleVersion,Rational InputAmount,Rational TaxableAmount,
    IReadOnlyList<RomanianTaxCharge> Charges,Rational? TotalLiability,Rational? RemainingCash,int Items,bool InputApproximate,string Basis)
{
    public Rational? PensionBase { get; init; }
    public Rational? HealthBase { get; init; }
    public Rational? DeductibleHealth { get; init; }
    public IReadOnlyList<string> Sources { get; init; }=[];
}
internal sealed record RomanianTaxResult(SheetValue Value,string Assumption,RomanianTaxEvidence Evidence);

/// <summary>Explicit 2026 Romanian rate models. Represented amounts stay exact before filing/withholding rounding.</summary>
internal sealed class RomanianTaxArithmetic(ExecutionBudget budget,CancellationToken token)
{
    internal const int Year=2026;
    internal const int JanuaryMinimum=4050;
    private readonly ExactArithmetic math=new(budget,token);
    private bool approximate,monetary;
    private CurrencyRateStamp? stamp;
    private static readonly Rational Bound=new(100_000_000,1);
    private static readonly Rational Six=new(JanuaryMinimum*6,1),Twelve=new(JanuaryMinimum*12,1),TwentyFour=new(JanuaryMinimum*24,1),SeventyTwo=new(JanuaryMinimum*72,1);
    private const string Code="https://static.anaf.ro/static/10/Anaf/legislatie/Cod_fiscal_norme_2023.htm";
    private const string Law239="https://static.anaf.ro/static/10/Anaf/legislatie/L_239_2025.pdf";
    private const string Law141="https://static.anaf.ro/static/10/Anaf/legislatie/L_141_2025.pdf";
    private const string Oug89="https://static.anaf.ro/static/10/Anaf/legislatie/OUG_89_2025.pdf";
    internal static bool IsFunction(string name)=>name.ToLowerInvariant() is "pfanetro" or "pfataxro" or "microtaxro" or "dividendtaxro" or "dividendcashro" or "stocktaxro" or "brokertaxro" or "brokergainsro" or "cryptotaxro" or "investmentcassro";
    internal static void ValidateArity(string name,int count)
    {
        var (minimum,maximum)=name.ToLowerInvariant() switch
        { "pfanetro" or "pfataxro"=>(3,5),"microtaxro" or "brokertaxro"=>(3,3),"stocktaxro"=>(2,3),_=>(2,2) };
        if(count<minimum || count>maximum) throw new FormatException($"{name} expects {minimum}–{maximum} arguments; tax year is explicit");
    }
    private Rational Add(Rational a,Rational b) { budget.Step(token); return math.Add(new(a),new(b)).Rational; }
    private Rational Subtract(Rational a,Rational b) { budget.Step(token); return math.Subtract(new(a),new(b)).Rational; }
    private Rational Multiply(Rational a,Rational b) { budget.Step(token); return math.Multiply(new(a),new(b)).Rational; }
    private int Compare(Rational a,Rational b) { budget.Step(token); return (a.Numerator*b.Denominator).CompareTo(b.Numerator*a.Denominator); }
    private static Rational Positive(Rational a)=>a.Numerator.Sign<0?default:a;
    private Rational Min(Rational a,Rational b)=>Compare(a,b)<=0?a:b;
    private Rational Checked(Rational a)
    {
        if(Compare(new(System.Numerics.BigInteger.Abs(a.Numerator),a.Denominator),Bound)>0) throw new ArithmeticException("Romanian tax amount/aggregate exceeds 100,000,000 model units");
        return a;
    }
    private static NumericValue Scalar(SheetValue value)
    {
        var number=value.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("Romanian tax inputs require rational amounts without units or percentages");
        return number;
    }
    private Rational Cash(SheetValue value,bool nonnegative=false)
    {
        budget.Step(token); NumericValue number;
        if(value.Kind==SheetValueKind.Money)
        {
            var cash=value.Money;
            if(cash.Currency!="RON") throw new ArithmeticException("Romanian tax cash inputs must already be RON; choose any required statutory currency conversion explicitly");
            if(stamp is not null && cash.RateStamp is not null && stamp.Key!=cash.RateSnapshotKey) throw new ArithmeticException("Romanian tax inputs use conflicting currency snapshots");
            stamp??=cash.RateStamp; monetary=true; number=cash.Magnitude;
            if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("Romanian tax requires monetary amounts without physical rate units");
        }
        else number=Scalar(value);
        approximate|=number.IsApproximate; var amount=Checked(number.Scalar);
        if(nonnegative && amount.Numerator.Sign<0) throw new ArithmeticException("This Romanian tax input must be nonnegative");
        return amount;
    }
    private static int Integer(SheetValue value,int maximum,string name)
    {
        var number=Scalar(value); var amount=number.Scalar;
        if(number.IsApproximate || amount.Denominator!=1 || amount.Numerator<0 || amount.Numerator>maximum) throw new ArithmeticException(name+" requires an exact bounded whole number");
        return (int)amount.Numerator;
    }
    private Rational[] CashItems(SheetValue value,bool nonnegative=false)
    {
        var values=value.Kind==SheetValueKind.List?value.List.Values:new[]{value};
        return values.Select(item=>Cash(item,nonnegative)).ToArray();
    }
    private Rational Sum(IEnumerable<Rational> values)
    { var result=default(Rational); foreach(var value in values) result=Add(result,value); return Checked(result); }
    private SheetValue Output(Rational value)
    {
        var number=new NumericValue(value){DisplayDecimalPlaces=4,IsApproximate=approximate};
        return monetary?new(new MoneyValue(number,"RON",stamp)):new(number);
    }
    internal RomanianTaxResult Function(string name,SheetValue[] args)
    {
        ValidateArity(name,args.Length); var key=name.ToLowerInvariant();
        var yearIndex=key is "pfanetro" or "pfataxro" or "microtaxro" or "brokertaxro"?2:1;
        if(Integer(args[yearIndex],9999,"Tax year")!=Year) throw new ArithmeticException("Romanian tax models support explicit tax year 2026 only");
        var charges=new List<RomanianTaxCharge>(); Rational input=default,taxable=default,total=default,returned=default;
        Rational? remaining=null,pensionBase=null,healthBase=null,deductibleHealth=null;
        var items=1; string scope; string[] sources;
        if(key is "pfanetro" or "pfataxro")
        {
            var receipts=Cash(args[0],true); var expenses=Cash(args[1],true); input=Subtract(receipts,expenses);
            var casExempt=args.Length>3 && Integer(args[3],1,"CAS exemption flag")==1;
            var floorExempt=args.Length>4 && Integer(args[4],1,"CASS floor exemption flag")==1;
            var positive=Positive(input);
            pensionBase=casExempt || Compare(positive,Twelve)<0?default(Rational):Compare(positive,TwentyFour)<0?Twelve:TwentyFour;
            var cas=Multiply(pensionBase.Value,new(1,4));
            healthBase=Min(positive,SeventyTwo); var cass=Multiply(healthBase.Value,new(1,10)); deductibleHealth=cass;
            var topUp=!floorExempt && positive.Numerator.Sign>0 && Compare(positive,Six)<0?Subtract(new(2430,1),cass):default;
            taxable=Positive(Subtract(Subtract(positive,cas),cass)); var income=Multiply(taxable,new(1,10));
            charges.AddRange([new("Income tax",income),new("CAS minimum pension",cas),new("CASS on income",cass),new("CASS nondeductible floor top-up",topUp)]);
            total=Sum(charges.Select(row=>row.Amount)); remaining=Subtract(input,total); returned=key=="pfanetro"?remaining.Value:total;
            scope="Annual single-source PFA real-system model; receipts less eligible expenses excluding social contributions; no other independent/IP/sports income, loss carryforward, foreign credit, voluntary/higher CAS base or norm-of-income regime; minimum mandatory CAS base; CAS exemption asserted="+casExempt+", CASS floor exception asserted="+floorExempt+
                "; a floor exception removes only the top-up, not 10% income CASS; January minimum 4050 RON fixes all 2026 annual thresholds; CASS income cap 291600 RON; floor top-up is not income-tax deductible; negative/zero profit has no mandatory contributions in this profile";
            sources=[Code,Law239,"https://static.anaf.ro/static/10/Anaf/legislatie/HG_1506_2024.pdf"];
        }
        else if(key=="microtaxro")
        {
            var bases=CashItems(args[0],true); if(bases.Length>4) throw new ArithmeticException("Micro tax accepts one quarter base or at most four quarterly bases"); items=bases.Length; input=taxable=Sum(bases);
            var group=args[1]; var number=group.Kind==SheetValueKind.Money && group.Money.Currency=="EUR"?group.Money.Magnitude:Scalar(group);
            if(!number.IsRational || number.Unit is not null || number.IsPercentage || number.IsApproximate || number.Scalar.Numerator.Sign<0 || Compare(number.Scalar,new(100000,1))>0)
                throw new ArithmeticException("Eligible 2026 micro profile requires explicit annual linked-group turnover of 0–100000 EUR; threshold exit needs quarterly profit-tax treatment");
            total=returned=Multiply(taxable,new(1,100)); charges.Add(new("Micro-company turnover tax",total));
            scope="Eligible Romanian 2026 micro regime asserted, including employment, ownership, filings and exclusions; Article 53 tax bases supplied for one quarter or up to four quarters; annual linked-group turnover declared "+number.Scalar+" EUR using the statutory prior-year-end valuation, not a live exchange rate; this is company tax only, with no inferred distributable profit, dividends, payroll, credits or threshold-exit switch";
            sources=[Code,Oug89,"https://static.anaf.ro/static/3/Cluj/20260402144800_cj_micro_02apr2026.pdf"];
        }
        else if(key is "dividendtaxro" or "dividendcashro")
        {
            var amounts=CashItems(args[0],true); items=amounts.Length; input=taxable=Sum(amounts); total=Multiply(taxable,new(16,100)); remaining=Subtract(input,total);
            charges.Add(new("Dividend income tax",total)); returned=key=="dividendcashro"?remaining.Value:total;
            scope="Romanian resident individual, dividends distributed and paid in 2026; 16% income-tax model; excludes 2025 interim distributions, foreign credits and exempt corporate recipients; dividendCashRO is cash after income tax only, BEFORE any aggregated investment CASS; paid dividends after withholding are the ordinary Article 170 dividend assessment input";
            sources=[Code,Law141];
        }
        else if(key=="stocktaxro")
        {
            var gains=CashItems(args[0]); items=gains.Length; input=Sum(gains); var carry=args.Length>2?Cash(args[2],true):default;
            var used=Min(carry,Multiply(Positive(input),new(70,100))); taxable=Subtract(Positive(input),used); total=returned=Multiply(taxable,new(16,100)); charges.Add(new("Annual securities income tax",total));
            scope="Annual non-withholding securities/investment-gold regime, one homogeneous eligible country/source pool; signed current-year net gains/losses, plus declared valid carryforward subject to 70% cap; used carryforward "+used+" RON; no cross-country pooling, legacy-loss expiry/order, foreign credits or qualifying-intermediary treatment inferred; investment CASS uses the applicable current gain basis before prior-loss carryforward, separately";
            sources=[Code,Law239];
        }
        else if(key is "brokertaxro" or "brokergainsro")
        {
            var gains=CashItems(args[0]); items=gains.Length; input=Sum(gains); taxable=Sum(gains.Select(Positive));
            if(key=="brokergainsro") { returned=taxable; scope="Positive realized gains for the qualifying-intermediary regime; losses are not netted against gains; helper returns gains, not a tax or final take-home amount; the caller determines the complete annual investment CASS assessment"; }
            else
            {
                var days=args[1].Kind==SheetValueKind.List?args[1].List.Values:new[]{args[1]};
                if(days.Count!=1 && days.Count!=gains.Length) throw new ArithmeticException("Broker holding-day list must match gains, or supply one day count for all trades");
                if(days.Count==0 && gains.Length!=0) throw new ArithmeticException("Missing broker holding days");
                var periods=days.Select(value=>Integer(value,100000,"Holding days")).ToArray();
                var shortTax=default(Rational); var longTax=default(Rational);
                for(var i=0;i<gains.Length;i++)
                { budget.Step(token); var longHeld=periods[periods.Length==1?0:i]>=365; var tax=Multiply(Positive(gains[i]),new(longHeld?3:6,100)); if(longHeld) longTax=Add(longTax,tax); else shortTax=Add(shortTax,tax); }
                charges.AddRange([new("Broker gains held under 365 days",shortTax),new("Broker gains held at least 365 days",longTax)]); total=returned=Add(shortTax,longTax);
                scope="Qualifying Article 96.1 intermediary regime; 6% per positive realized gain below 365 holding days, 3% from 365 days inclusive; losses do not offset tax; supplied whole holding days and cost-adjusted gains must reflect the applicable lot/FIFO and acquisition-date rules; no lot matching or CASS is inferred";
            }
            sources=[Code,Law239];
        }
        else if(key=="cryptotaxro")
        {
            var gains=CashItems(args[0]); items=gains.Length; input=Sum(gains); var positive=Sum(gains.Select(Positive));
            taxable=Compare(positive,new(600,1))<=0?Sum(gains.Where(gain=>Compare(gain,new(200,1))>=0)):positive;
            total=returned=Multiply(taxable,new(16,100)); charges.Add(new("Crypto gain income tax",total));
            scope="Complete annual realized transaction gains after acquisition and direct costs; 16% on positive gains without loss netting; only gains STRICTLY below 200 RON are exempt when the entire year's positive gains total at most 600 RON; no wallet cost basis, lot matching, currency conversion or aggregated CASS assessment is inferred";
            sources=[Code,Law239];
        }
        else
        {
            var bases=CashItems(args[0],true); items=bases.Length; input=Sum(bases);
            healthBase=Compare(input,Six)<0?default(Rational):Compare(input,Twelve)<0?Six:Compare(input,TwentyFour)<0?Twelve:TwentyFour;
            taxable=healthBase.Value; total=returned=Multiply(taxable,new(1,10)); charges.Add(new("Aggregated investment/other-income CASS",total));
            scope="One annual aggregate of already prepared eligible Article 155(c–h)/170 assessment amounts; 6/12/24 January minimum-wage thresholds 24300/48600/97200 RON; do not apply once per asset/category; PFA health contributions are a SEPARATE income stream; dividend assessment ordinarily uses paid dividends after withholding; caller prepares each other category's statutory gain/income basis and exemptions; no exemption, prior-payment credit, dividend timing or foreign-currency valuation is inferred";
            sources=[Code,"https://static.anaf.ro/static/10/Anaf/legislatie/HG_1506_2024.pdf"];
        }
        var rule="RO-"+(key is "pfanetro" or "pfataxro"?"PFA-real":key=="microtaxro"?"micro":key.StartsWith("dividend",StringComparison.Ordinal)?"dividend":key=="stocktaxro"?"securities-annual":key.StartsWith("broker",StringComparison.Ordinal)?"securities-broker":key=="cryptotaxro"?"crypto":"investment-CASS")+"-2026-v1";
        var basis="Exact represented rate-model arithmetic BEFORE statutory return, per-payment, withholding and whole-leu rounding; cash model units RON, input lists are complete within the declared model; no filing or eligibility certification";
        Rational? liability=key=="brokergainsro"?null:total;
        var label=key switch
        {
            "pfanetro"=>"Romanian PFA cash after modeled taxes", "pfataxro"=>"Romanian PFA tax and contributions", "microtaxro"=>"Romanian eligible micro-company tax",
            "dividendtaxro"=>"Romanian dividend income tax", "dividendcashro"=>"Romanian dividends after income tax, before CASS",
            "stocktaxro"=>"Romanian annual securities income tax", "brokertaxro"=>"Romanian qualifying-broker gains tax", "brokergainsro"=>"Romanian qualifying-broker positive gains",
            "cryptotaxro"=>"Romanian realized crypto gain tax", _=>"Romanian annual aggregated investment CASS"
        };
        var detail=label+", 2026; before filing/withholding rounding; rule "+rule+"; "+scope+"; "+basis+"; input "+input+" RON; taxable/assessment base "+taxable+" RON; "+
            string.Join("; ",charges.Select(row=>row.Name+" "+row.Amount+" RON"))+(liability is { } owing?"; total modeled liability "+owing+" RON":"; tax liability not calculated by this gain helper")+(remaining is { } cash?"; modeled remaining cash "+cash+" RON":"")+
            (approximate?"; upstream represented input is approximate":"; exact represented input")+(stamp is not null?"; upstream currency snapshot "+stamp.Provider+" as of "+stamp.AsOf.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture)+"; not a statutory BNR valuation certificate":"")+"; sources "+string.Join("; ",sources);
        var evidence=new RomanianTaxEvidence(key,Year,rule,input,taxable,charges.AsReadOnly(),liability,remaining,items,approximate,basis)
            {PensionBase=pensionBase,HealthBase=healthBase,DeductibleHealth=deductibleHealth,Sources=Array.AsReadOnly(sources)};
        return new(Output(returned),detail,evidence);
    }
}
