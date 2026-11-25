using System.Globalization;
using System.Numerics;

namespace Calc.Core;

internal sealed record GermanSalaryOptions(int TaxClass=1,int Children=0,decimal ChildAllowances=0,decimal? HealthSurchargePercent=null,
    bool Saxony=false,bool ChildlessSurcharge=true,int ChurchTaxPercent=0);

public sealed record GermanPayrollEvidence(string Period,int TaxClass,decimal Gross,decimal Net,decimal WageTax,decimal Solidarity,
    decimal ChurchTaxBase,decimal ChurchTax,decimal Pension,decimal Unemployment,decimal Health,decimal Care,
    decimal AnnualTaxableIncome,decimal AnnualProvisionAllowance,decimal AnnualTableAllowances,int Children,decimal ChildAllowances,
    decimal HealthSurchargePercent,bool Saxony,bool ChildlessSurcharge,int ChurchTaxPercent);

/// <summary>Germany 2026 current-wage employee model: official BMF wage-tax program plus statutory employee
/// social-insurance shares. Monthly input runs one monthly payroll period (LZZ 2); annual input runs the
/// annual table (LZZ 1). Whole-cent domain above the Übergangsbereich.</summary>
internal sealed class GermanSalaryArithmetic(ExecutionBudget budget,CancellationToken token,MoneyArithmetic money,EvaluationContext context,ContextReads reads)
{
    internal const string RuleVersion="DE-employee-2026-v1";
    internal const decimal DefaultHealthSurcharge=2.9m;
    private const decimal HealthCeiling=69750m, PensionCeiling=101400m;
    private const long MinimumMonthlyCents=200001, MinimumAnnualCents=2400001;
    private const long MaximumAnnualCents=(long)PayrollArithmetic.MaxAnnualGross*100, MaximumMonthlyCents=MaximumAnnualCents/12;
    // Bound on how far net can fall after a lower gross (cent rounding of tax/contributions); the oracle's
    // exhaustive windows observed at most 27 (monthly) and 108 (annual) cents.
    internal const long MonthlyDipBoundCents=200, AnnualDipBoundCents=2000;
    internal static readonly string[] Sources=[
        "https://www.bmf-steuerrechner.de/javax.faces.resource/daten/xmls/Lohnsteuer2026.xml.xhtml",
        "https://www.ihk-muenchen.de/ihk/documents/Recht-Steuern/Steuerrecht/Einkommensteuer/2025-11-12-PAP-2026-anlage-1.pdf",
        "https://www.gesetze-im-internet.de/svbezgrv_2026/__4.html",
        "https://www.gesetze-im-internet.de/sgb_5/__241.html",
        "https://www.bundesanzeiger.de/pub/publication/oUJYVk8GYRXybnb9Y4h/content/oUJYVk8GYRXybnb9Y4h/BAnz%20AT%2010.11.2025%20B7.pdf"];
    private readonly ExactArithmetic math=new(budget,token);
    private bool approximate;
    private string? outputCurrency;
    private CurrencyRateStamp? stamp;

    internal sealed record Monthly(long Gross,long Net,GermanWageTaxResult Tax,long ChurchTax,long Pension,long Unemployment,long Health,long Care);

    private static long HalfUpCents(decimal euros)=>(long)decimal.Round(euros*100m,0,MidpointRounding.AwayFromZero);
    internal static Monthly Calculate(long grossCents,bool annual,GermanSalaryOptions options)
    {
        var surcharge=options.HealthSurchargePercent??DefaultHealthSurcharge;
        var childless=options.Children==0 && options.ChildlessSurcharge;
        var discounts=Math.Max(0,Math.Min(options.Children,5)-1);
        var tax=GermanWageTax2026.Calculate(new(annual?1:2,grossCents,options.TaxClass,options.ChildAllowances,surcharge,
            options.Saxony,childless,discounts,options.ChurchTaxPercent>0));
        var church=options.ChurchTaxPercent>0?(long)decimal.Truncate(tax.ChurchBaseCents*options.ChurchTaxPercent/100m):0;
        var gross=grossCents/100m; var divisor=annual?1m:12m;
        var healthBase=Math.Min(gross,HealthCeiling/divisor); var pensionBase=Math.Min(gross,PensionCeiling/divisor);
        var careRate=(options.Saxony?0.023m:0.018m)+(childless?0.006m:0m)-0.0025m*discounts;
        var pension=HalfUpCents(pensionBase*0.093m); var unemployment=HalfUpCents(pensionBase*0.013m);
        var health=HalfUpCents(healthBase*(0.073m+surcharge/200m)); var care=HalfUpCents(healthBase*careRate);
        var net=grossCents-(long)tax.WageTaxCents-(long)tax.SolidarityCents-church-pension-unemployment-health-care;
        return new(grossCents,net,tax,church,pension,unemployment,health,care);
    }
    private Monthly Forward(long gross,bool annual,GermanSalaryOptions options) { budget.Step(token); return Calculate(gross,annual,options); }
    private long Inverse(long target,bool annual,GermanSalaryOptions options)
    {
        long low=annual?MinimumAnnualCents:MinimumMonthlyCents, high=annual?MaximumAnnualCents:MaximumMonthlyCents;
        var dip=annual?AnnualDipBoundCents:MonthlyDipBoundCents;
        if(Forward(high,annual,options).Net<target) throw new ArithmeticException("Target net exceeds the supported German gross bound");
        long crossing;
        if(Forward(low,annual,options).Net>=target) crossing=low;
        else
        {
            long below=low, above=high; // Net(below) < target <= Net(above)
            while(above-below>1)
            {
                var middle=below+(above-below)/2;
                if(Forward(middle,annual,options).Net>=target) above=middle; else below=middle;
            }
            crossing=above;
        }
        // No gross below a point whose net is more than the dip bound under the target can reach the target.
        long? lowest=null;
        for(var gross=crossing-1;gross>=low;gross--)
        {
            var net=Forward(gross,annual,options).Net;
            if(net==target) lowest=gross;
            if(net<target-dip) break;
        }
        if(lowest is { } found) return found;
        for(var gross=crossing;gross<=high;gross++)
        {
            var net=Forward(gross,annual,options).Net;
            if(net==target) return gross;
            if(net>target+dip) break;
        }
        throw new ArithmeticException("No whole-cent gross within the supported German profile produces this exact net");
    }
    private SheetValue Output(decimal euros)
    {
        var number=new NumericValue(Rational.Parse(euros.ToString(CultureInfo.InvariantCulture))){DisplayDecimalPlaces=4,IsApproximate=approximate};
        return outputCurrency is null?new(number):new(new MoneyValue(number,outputCurrency,stamp));
    }
    internal PayrollResult Evaluate(SalaryExpression expression,SheetValue value,string origin)
    {
        var options=expression.German??new();
        if(options.TaxClass is < 1 or > 6) throw new ArithmeticException("German tax class must be 1 through 6");
        if(options.ChildAllowances>0 && options.TaxClass>4) throw new ArithmeticException("Child allowances apply only in German tax classes 1 through 4");
        var year=expression.Year ?? expression.PayrollDate?.Year;
        if(year is null) { reads.Dependencies|=ContextDependency.Date; year=context.RequireToday().Year; }
        if(year!=2026) throw new ArithmeticException($"German salary rules unavailable for {year}; supported 2026 only");
        var hadPeriod=value.Kind==SheetValueKind.Earnings;
        var period=hadPeriod?value.Earnings.Period:EarningsPeriod.Year;
        if(period is not EarningsPeriod.Month and not EarningsPeriod.Year) throw new ArithmeticException("Annualize hourly/workday earnings explicitly before applying salary rules");
        var annual=period==EarningsPeriod.Year;
        var amount=hadPeriod?value.Earnings.Amount:value;
        if(amount.Kind==SheetValueKind.Money)
        {
            var converted=money.Convert(amount.Money,"EUR"); outputCurrency="EUR"; stamp=converted.RateStamp; amount=new(converted.Magnitude);
        }
        var number=amount.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("German salary requires a rational EUR amount without units or percentages");
        approximate=number.IsApproximate;
        var scaled=math.Multiply(new(number.Scalar),new(new Rational(100,1))).Rational;
        if(scaled.Denominator!=BigInteger.One || scaled.Numerator.Sign<0) throw new ArithmeticException("German salary requires a nonnegative whole-cent amount");
        long minimum=annual?MinimumAnnualCents:MinimumMonthlyCents, maximum=annual?MaximumAnnualCents:MaximumMonthlyCents;
        if(scaled.Numerator>maximum) throw new ArithmeticException("Salary amount must be at most 100,000,000 EUR annually");
        var input=(long)scaled.Numerator;
        var gross=expression.Inverse?Inverse(input,annual,options):input;
        if(gross<minimum) throw new ArithmeticException(annual?"German model requires annual gross above 24,000 EUR; Minijob/Übergangsbereich contributions are unavailable":
            "German model requires monthly gross above 2,000 EUR; Minijob/Übergangsbereich contributions are unavailable");
        var result=Forward(gross,annual,options);
        var returned=expression.Inverse?result.Gross:result.Net;
        var output=Output(returned/100m);
        if(hadPeriod) output=new(new EarningsValue(output,period));
        var surcharge=options.HealthSurchargePercent??DefaultHealthSurcharge;
        var childless=options.Children==0 && options.ChildlessSurcharge;
        string E(long cents)=>(cents/100m).ToString("0.00",CultureInfo.InvariantCulture)+" EUR";
        var label=annual?"annual":"monthly";
        var detail=$"German salary {(expression.Inverse?"net to gross":"gross to net")}; DE from {origin}; {RuleVersion}; 2026 {label} payroll period (PAP LZZ {(annual?1:2)}); tax class {options.TaxClass}"+
            $"; child allowances {options.ChildAllowances.ToString(CultureInfo.InvariantCulture)}; children for care insurance {options.Children}"+
            (childless?"; childless care surcharge (age 23 or older assumed)":options.Children>0?"; parent care rate"+(options.Children>1?$" with {Math.Min(options.Children,5)-1} child discount(s), children under 25 assumed":""):"; no childless care surcharge")+
            $"; statutory health insurance with {surcharge.ToString(CultureInfo.InvariantCulture)}% Zusatzbeitrag{(options.HealthSurchargePercent is null?" (2026 average)":"")}"+
            (options.Saxony?"; Saxony care insurance split":"")+(options.ChurchTaxPercent>0?$"; church tax {options.ChurchTaxPercent}%":"; no church tax")+
            $"; gross {E(result.Gross)}; wage tax {E((long)result.Tax.WageTaxCents)}; solidarity surcharge {E((long)result.Tax.SolidarityCents)}"+
            (options.ChurchTaxPercent>0?$"; church tax {E(result.ChurchTax)} on base {E((long)result.Tax.ChurchBaseCents)}":"")+
            $"; pension {E(result.Pension)}; unemployment {E(result.Unemployment)}; health {E(result.Health)}; care {E(result.Care)}; net {E(result.Net)}"+
            $"; annual taxable income {result.Tax.AnnualTaxableIncome.ToString("0.00",CultureInfo.InvariantCulture)} EUR after Vorsorgepauschale {result.Tax.AnnualProvisionAllowance.ToString(CultureInfo.InvariantCulture)} EUR"+
            "; BMF 2026 machine wage-tax program, current wage only; employee contribution shares rounded half up to cents per branch; church tax truncated to cents; no Minijob/Übergangsbereich, private insurance, Versorgungsbezüge, other payments, allowances on the tax card, factor method, U1/U2/insolvency levies or employer cost"+
            (annual?"; annual table and ceilings, not twelve settled monthly runs":"; one monthly payroll period, not annual reconciliation")+
            (expression.Inverse?"; lowest whole-cent gross producing the exact net, verified by recomputing; other gross amounts may produce the same net":"")+
            (approximate?"; upstream amount is approximate":"; exact represented amount")+
            (money.Provenance is { } provenance?"; "+provenance:"");
        if(expression.OutputPeriod is { } target)
        {
            var rate=hadPeriod?output:new SheetValue(new EarningsValue(output,EarningsPeriod.Year));
            var converter=new EarningsArithmetic(math,money,new WorkdayArithmetic(budget,token),context,reads,token);
            output=converter.Convert(rate,target); detail+="; "+converter.Assumption;
        }
        detail+="; rule sources "+string.Join("; ",Sources);
        var periods=annual?1:12;
        Rational A(decimal euros)=>Rational.Parse((euros*periods).ToString(CultureInfo.InvariantCulture));
        Rational C(long cents)=>A(cents/100m);
        PayrollDeduction[] deductions=[new("Wage tax",C((long)result.Tax.WageTaxCents)),new("Solidarity surcharge",C((long)result.Tax.SolidarityCents)),
            new("Church tax",C(result.ChurchTax)),new("Pension insurance",C(result.Pension)),new("Unemployment insurance",C(result.Unemployment)),
            new("Health insurance",C(result.Health)),new("Care insurance",C(result.Care))];
        var german=new GermanPayrollEvidence(label,options.TaxClass,result.Gross/100m,result.Net/100m,result.Tax.WageTaxCents/100m,result.Tax.SolidarityCents/100m,
            result.Tax.ChurchBaseCents/100m,result.ChurchTax/100m,result.Pension/100m,result.Unemployment/100m,result.Health/100m,result.Care/100m,
            result.Tax.AnnualTaxableIncome,result.Tax.AnnualProvisionAllowance,result.Tax.AnnualTableAllowances,options.Children,options.ChildAllowances,
            surcharge,options.Saxony,childless,options.ChurchTaxPercent);
        var evidence=new PayrollEvidence("DE",2026,RuleVersion,C(result.Gross),C(result.Net),
            Rational.Parse((result.Tax.AnnualTableAllowances+result.Tax.AnnualProvisionAllowance).ToString(CultureInfo.InvariantCulture)),
            Rational.Parse(result.Tax.AnnualTaxableIncome.ToString(CultureInfo.InvariantCulture)),Array.AsReadOnly(deductions),expression.Inverse,approximate,
            annual?"German 2026 annual wage-tax table and employee social insurance":"German 2026 monthly payroll period; annual fields project twelve identical months")
            {Sources=Array.AsReadOnly(Sources),German=german};
        return new(output,detail,evidence);
    }
}
