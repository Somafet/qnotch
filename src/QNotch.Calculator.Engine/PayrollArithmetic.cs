using System.Numerics;

namespace Calc.Core;

public sealed record PayrollDeduction(string Name,Rational AnnualAmount);
public sealed record PayrollEvidence(string Country,int TaxYear,string RuleVersion,Rational AnnualGross,Rational AnnualNet,
    Rational AnnualAllowance,Rational AnnualTaxableIncome,IReadOnlyList<PayrollDeduction> Deductions,bool Inverse,bool InputApproximate,string Basis)
{
    public IReadOnlyList<string> Sources { get; init; } = [];
    public RomanianPayrollEvidence? Romanian { get; init; }
    public GermanPayrollEvidence? German { get; init; }
    public HungarianPayrollEvidence? Hungarian { get; init; }
}
internal sealed record PayrollResult(SheetValue Value,string Assumption,PayrollEvidence Evidence);

/// <summary>Dated standard employee models. Exact annualized arithmetic, separate from payroll settlement.</summary>
internal sealed class PayrollArithmetic(ExecutionBudget budget,CancellationToken token,MoneyArithmetic money,EvaluationContext context,ContextReads reads)
{
    internal const int SupportedYear=2026;
    internal const int MaxAnnualGross=100_000_000;
    private readonly ExactArithmetic math=new(budget,token);
    private bool approximate;
    private string? outputCurrency;
    private CurrencyRateStamp? stamp;
    private Rational Add(Rational a,Rational b)=>math.Add(new(a),new(b)).Rational;
    private Rational Subtract(Rational a,Rational b)=>math.Subtract(new(a),new(b)).Rational;
    private Rational Multiply(Rational a,Rational b)=>math.Multiply(new(a),new(b)).Rational;
    private Rational Divide(Rational a,Rational b)=>math.Divide(new(a),new(b)).Rational;
    private int Compare(Rational a,Rational b) { budget.Step(token); return (a.Numerator*b.Denominator).CompareTo(b.Numerator*a.Denominator); }
    private Rational MaxZero(Rational value)=>value.Numerator.Sign<0?default:value;
    private Rational Min(Rational a,Rational b)=>Compare(a,b)<=0?a:b;
    private Rational Plain(SheetValue value)
    {
        var number=value.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("Salary requires a rational amount without physical units or percentages");
        approximate |= number.IsApproximate; return number.Scalar;
    }
    private SheetValue Output(Rational value)
    {
        var number=new NumericValue(value){DisplayDecimalPlaces=4,IsApproximate=approximate};
        return outputCurrency is null?new(number):new(new MoneyValue(number,outputCurrency,stamp));
    }
    private (string Country,string Origin) Country(string? explicitCountry,SheetValue amount)
    {
        if(explicitCountry is not null) return (NormalizeCountry(explicitCountry),"explicit country");
        if(amount.Kind==SheetValueKind.Money)
        {
            var inferred=amount.Money.Currency switch {"USD"=>"US","GBP"=>"UK","RON"=>"RO","EUR"=>"DE","HUF"=>"HU",_=>null};
            if(inferred is not null) return (inferred,"input currency");
        }
        reads.Dependencies |= ContextDependency.PayrollRegion;
        if(string.IsNullOrWhiteSpace(context.PayrollRegion)) throw new ArithmeticException("Salary country unavailable; specify in US, UK, DE, RO or HU");
        return (NormalizeCountry(context.PayrollRegion),"injected payroll region");
    }
    private static string NormalizeCountry(string value)
    {
        if(value.Length!=2 || !value.All(char.IsAsciiLetter)) throw new ArithmeticException("Salary country requires a two-letter region");
        return value.ToUpperInvariant() is "GB"?"UK":value.ToUpperInvariant();
    }
    private int Year(string country,int? explicitYear)
    {
        if(explicitYear is { } year) return year;
        reads.Dependencies |= ContextDependency.Date;
        var today=context.RequireToday();
        return country=="UK" && today<new DateOnly(today.Year,4,6)?today.Year-1:today.Year;
    }
    private sealed record Annual(Rational Gross,Rational Net,Rational Allowance,Rational Taxable,PayrollDeduction[] Deductions);
    private Rational LayerTax(Rational taxable,(int Upper,int Rate)[] bands)
    {
        var result=default(Rational); var lower=0;
        foreach(var (upper,rate) in bands)
        {
            budget.Step(token); var width=MaxZero(Subtract(Min(taxable,new(upper,1)),new(lower,1)));
            result=Add(result,Multiply(width,new(rate,100))); lower=upper;
        }
        return result;
    }
    private Annual Forward(string country,Rational gross)
    {
        budget.Step(token);
        Rational allowance,taxable; PayrollDeduction[] deductions;
        if(country=="US")
        {
            allowance=new(16100,1); taxable=MaxZero(Subtract(gross,allowance));
            var income=LayerTax(taxable,[(12400,10),(50400,12),(105700,22),(201775,24),(256225,32),(640600,35),(MaxAnnualGross,37)]);
            deductions=[new("Federal income tax",income),new("Social Security",Multiply(Min(gross,new(184500,1)),new(62,1000))),
                new("Medicare",Multiply(gross,new(145,10000))),new("Additional Medicare",Multiply(MaxZero(Subtract(gross,new(200000,1))),new(9,1000)))];
        }
        else
        {
            allowance=MaxZero(Subtract(new(12570,1),Divide(MaxZero(Subtract(gross,new(100000,1))),new(2,1))));
            taxable=MaxZero(Subtract(gross,allowance));
            var income=LayerTax(taxable,[(37700,20),(125140,40),(MaxAnnualGross,45)]);
            var basicNi=Multiply(Min(MaxZero(Subtract(gross,new(12570,1))),new(37700,1)),new(8,100));
            var upperNi=Multiply(MaxZero(Subtract(gross,new(50270,1))),new(2,100));
            deductions=[new("Income tax",income),new("Employee National Insurance",Add(basicNi,upperNi))];
        }
        var net=gross; foreach(var deduction in deductions) net=Subtract(net,deduction.AnnualAmount);
        return new(gross,net,allowance,taxable,deductions);
    }
    private Rational Inverse(string country,Rational target)
    {
        int[] edges=country=="US"?[0,16100,28500,66500,121800,184500,200000,217875,272325,656700,MaxAnnualGross]:[0,12570,50270,100000,125140,MaxAnnualGross];
        var low=Forward(country,default);
        for(var i=1;i<edges.Length;i++)
        {
            var high=Forward(country,new(edges[i],1));
            if(Compare(target,high.Net)<=0)
            {
                var gross=Add(low.Gross,Multiply(Subtract(target,low.Net),Divide(Subtract(high.Gross,low.Gross),Subtract(high.Net,low.Net))));
                if(Forward(country,gross).Net!=target) throw new ArithmeticException("Salary inverse verification failed within the precision bound");
                return gross;
            }
            low=high;
        }
        throw new ArithmeticException("Target net exceeds the supported annual gross bound");
    }
    internal PayrollResult Evaluate(SalaryExpression expression,SheetValue value)
    {
        var period=value.Kind==SheetValueKind.Earnings?value.Earnings.Period:EarningsPeriod.Year;
        var hadPeriod=value.Kind==SheetValueKind.Earnings;
        if(period is not EarningsPeriod.Month and not EarningsPeriod.Year) throw new ArithmeticException("Annualize hourly/workday earnings explicitly before applying salary rules");
        var amount=hadPeriod?value.Earnings.Amount:value;
        var (country,origin)=Country(expression.Country,amount);
        if(country=="HU") return new HungarianSalaryArithmetic(budget,token,money,context,reads).Evaluate(expression,value,origin);
        if(expression.Hungarian is not null) throw new ArithmeticException("Átalányadó, cost ratio, guaranteed minimum, pensioner, mothers' exemption and first-marriage options require Hungarian salary rules");
        if(country!="DE" && expression.German is not null) throw new ArithmeticException("Tax class, church tax, care-insurance children and health surcharge options require German salary rules");
        if(country=="RO") return new RomanianSalaryArithmetic(budget,token,money,context,reads).Evaluate(expression,value,origin);
        if(expression.Romanian is not null || expression.EmployerCost) throw new ArithmeticException("Dependants, school children, youth/minimum relief and employer cost currently require Romanian salary rules");
        if(country=="DE") return new GermanSalaryArithmetic(budget,token,money,context,reads).Evaluate(expression,value,origin);
        if(country is not "US" and not "UK") throw new ArithmeticException("Salary rules unavailable for "+country+"; supported US, UK, DE, RO and HU");
        var pinnedYear=expression.Year;
        if(expression.PayrollDate is { } date) pinnedYear=country=="UK" && date<new DateOnly(date.Year,4,6)?date.Year-1:date.Year;
        var year=Year(country,pinnedYear);
        if(year!=SupportedYear) throw new ArithmeticException($"Salary rules unavailable for {country} tax year {year}; supported {(country=="UK"?"2026/27":"2026")} only");
        if(amount.Kind==SheetValueKind.Money)
        {
            var native=country=="US"?"USD":"GBP"; var converted=money.Convert(amount.Money,native);
            outputCurrency=native; stamp=converted.RateStamp; amount=new(converted.Magnitude);
        }
        var input=Plain(amount); var periods=new Rational(period==EarningsPeriod.Month?12:1,1); var annualInput=Multiply(input,periods);
        if(annualInput.Numerator.Sign<0 || Compare(annualInput,new(MaxAnnualGross,1))>0) throw new ArithmeticException("Salary amount must be nonnegative and at most 100,000,000 annually");
        var gross=expression.Inverse?Inverse(country,annualInput):annualInput; var annual=Forward(country,gross);
        var output=Output(Divide(expression.Inverse?gross:annual.Net,periods));
        if(hadPeriod) output=new(new EarningsValue(output,period));
        var rule=country=="US"?"US-single-2026-v1":"UK-EWNI-A-2026-27-v1";
        var assumptions=country=="US"?"2026 calendar year; single employee under 65, not blind/dependent; standard deduction 16100 USD; federal income tax plus employee FICA; no state/local tax, credits, itemized/special deductions, benefits or pension contributions":
            "2026/27 (6 April 2026–5 April 2027); England/Wales/Northern Ireland, standard personal allowance with continuous taper, Class 1 category A employee below pension age; annual NIC thresholds; no Scotland, student loans, pension, benefits or other reliefs";
        var detail="Salary "+(expression.Inverse?"net to gross":"gross to net")+"; "+country+" from "+origin+"; "+rule+"; "+assumptions+
            "; annualized continuous arithmetic before pay-period/statutory/cent settlement; "+(hadPeriod?period.ToString().ToLowerInvariant():"bare amount defaults to annual")+" input/output basis; source magnitude retained; display rounding is separate"+
            (approximate?"; upstream amount is approximate":"; exact represented amount")+(expression.Inverse?"; inverse verified by recomputing annual net":"")+
            "; annual gross "+Output(gross).Display+", allowance/deduction "+Output(annual.Allowance).Display+", taxable "+Output(annual.Taxable).Display+
            "; "+string.Join("; ",annual.Deductions.Select(row=>row.Name+" annual "+Output(row.AnnualAmount).Display))+"; annual net "+Output(annual.Net).Display+
            (money.Provenance is { } provenance?"; "+provenance:"");
        if(expression.OutputPeriod is { } target)
        {
            var rate=hadPeriod?output:new SheetValue(new EarningsValue(output,EarningsPeriod.Year));
            var converter=new EarningsArithmetic(math,money,new WorkdayArithmetic(budget,token),context,reads,token);
            output=converter.Convert(rate,target); detail+="; "+converter.Assumption;
        }
        string[] sources=country=="US"?["https://www.irs.gov/irb/2025-45_IRB","https://www.irs.gov/taxtopics/tc751"]:
            ["https://www.gov.uk/guidance/rates-and-thresholds-for-employers-2026-to-2027","https://www.gov.uk/income-tax-rates"];
        detail+="; rule sources "+string.Join("; ",sources);
        return new(output,detail,new PayrollEvidence(country,year,rule,gross,annual.Net,annual.Allowance,annual.Taxable,Array.AsReadOnly(annual.Deductions),expression.Inverse,approximate,"Annualized continuous standard employee model; settlement/exclusions disclosed"){Sources=Array.AsReadOnly(sources)});
    }
}
