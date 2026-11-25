using System.Numerics;
using System.Globalization;

namespace Calc.Core;

public sealed record RomanianPayrollEvidence(DateOnly PayrollMonth,Rational MonthlyGross,Rational MonthlyNet,
    Rational MonthlyBasicSalary,Rational ContributionBase,Rational MinimumRelief,Rational BaseDeduction,
    Rational YouthDeduction,Rational ChildDeduction,Rational AppliedDeduction,Rational TaxableIncome,
    Rational EmployerContribution,Rational EmployerCost,int Dependants,int SchoolChildren,bool YouthRelief,bool MainJob);

/// <summary>Full-month normal-condition employee model, with a pinned reporting month and whole-leu settlement.</summary>
internal sealed class RomanianSalaryArithmetic(ExecutionBudget budget,CancellationToken token,MoneyArithmetic money,EvaluationContext context,ContextReads reads)
{
    private readonly ExactArithmetic math=new(budget,token);
    private static readonly Rational Twelve=new(12,1);
    private const int MaxMonthlyGross=PayrollArithmetic.MaxAnnualGross/12;
    private bool approximate;
    private string? outputCurrency;
    private CurrencyRateStamp? stamp;
    private Rational Add(Rational a,Rational b)=>math.Add(new(a),new(b)).Rational;
    private Rational Subtract(Rational a,Rational b)=>math.Subtract(new(a),new(b)).Rational;
    private Rational Multiply(Rational a,Rational b)=>math.Multiply(new(a),new(b)).Rational;
    private Rational Divide(Rational a,Rational b)=>math.Divide(new(a),new(b)).Rational;
    private static Rational MaxZero(Rational a)=>a.Numerator.Sign<0?default:a;
    private Rational Min(Rational a,Rational b)
    { budget.Step(token); return a.Numerator*b.Denominator<=b.Numerator*a.Denominator?a:b; }
    private Rational Round(Rational value,bool contribution=false)
    {
        budget.Step(token);
        if(value.Numerator.Sign<0) throw new ArithmeticException("Negative Romanian payroll rounding input");
        var whole=BigInteger.DivRem(value.Numerator,value.Denominator,out var remainder);
        if(remainder*2>=value.Denominator) whole++;
        if(contribution && whole.IsZero && !value.Numerator.IsZero) whole=1;
        return new(whole,1);
    }
    private SheetValue Output(Rational value)
    {
        var number=new NumericValue(value){DisplayDecimalPlaces=4,IsApproximate=approximate};
        return outputCurrency is null?new(number):new(new MoneyValue(number,outputCurrency,stamp));
    }
    private sealed record Rules(DateOnly Month,int Minimum,int Relief,int ReliefCeiling)
    {
        internal string Version=>Month.Month<=6?"RO-employee-2026-H1-v1":"RO-employee-2026-H2-v1";
    }
    private Rules GetRules(SalaryExpression expression)
    {
        if(expression.Year is not null) throw new ArithmeticException("Romanian salary needs a payroll month; use for 2026-07-01 instead of a year alone");
        var date=expression.PayrollDate;
        if(date is null) { reads.Dependencies|=ContextDependency.Date; date=context.RequireToday(); }
        if(date.Value.Year!=2026) throw new ArithmeticException("Romanian salary rules available for January–December 2026 only");
        return date.Value.Month<=6?new(new(2026,date.Value.Month,1),4050,300,4300):new(new(2026,date.Value.Month,1),4325,200,4600);
    }
    private RomanianPayrollEvidence Forward(int gross,Rules rules,RomanianSalaryOptions options)
    {
        budget.Step(token);
        var basic=options.BasicSalary??gross;
        var dependants=options.Dependants??options.SchoolChildren;
        var relief=options.MinimumRelief && options.MainJob && basic==rules.Minimum && gross<=rules.ReliefCeiling?rules.Relief:0;
        var contributionBase=new Rational(gross-relief,1);
        var cas=Round(Multiply(contributionBase,new(1,4)),true);
        var cass=Round(Multiply(contributionBase,new(1,10)),true);
        Rational personal=default,youth=default,child=default;
        if(options.MainJob)
        {
            if(gross<=rules.Minimum+2000)
            {
                var band=(Math.Max(0,gross-rules.Minimum)+49)/50;
                int[] initial=[40,50,60,70,90]; // half percentage points, followed by one half-point decrease per band
                personal=Round(Multiply(new(rules.Minimum,1),new(initial[Math.Min(dependants,4)]-band,200)));
                if(options.YouthRelief) youth=Round(Multiply(new(rules.Minimum,1),new(15,100)));
            }
            child=new(options.SchoolChildren*100,1);
        }
        var available=MaxZero(Subtract(Subtract(contributionBase,cas),cass));
        var applied=Min(available,Add(Add(personal,youth),child));
        var taxable=MaxZero(Subtract(available,applied));
        var income=Round(Multiply(taxable,new(1,10)));
        var net=Subtract(Subtract(Subtract(new(gross,1),cas),cass),income);
        var employer=Round(Multiply(contributionBase,new(9,400)),true);
        return new(rules.Month,new(gross,1),net,new(basic,1),contributionBase,new(relief,1),personal,youth,child,applied,taxable,
            employer,Add(new(gross,1),employer),dependants,options.SchoolChildren,options.YouthRelief,options.MainJob);
    }
    private int Inverse(int target,Rules rules,RomanianSalaryOptions options)
    {
        // With a fixed deduction and relief, CAS quarter-leu and CASS tenth-leu rounding jumps
        // occur on disjoint integer gross steps. Net is nondecreasing within each interval.
        // Search EVERY interval in gross order: relief and deduction boundaries can lower net.
        var start=Math.Max(rules.Minimum,options.BasicSalary??0);
        var edges=new SortedSet<int>{start,MaxMonthlyGross+1};
        void Edge(int value) { if(value>start && value<=MaxMonthlyGross) edges.Add(value); }
        Edge(rules.Minimum+1);
        for(var band=1;band<=40;band++) Edge(rules.Minimum+50*band+1);
        Edge(rules.ReliefCeiling+1);
        var points=edges.ToArray();
        for(var index=0;index<points.Length-1;index++)
        {
            var low=points[index]; var high=points[index+1]-1;
            var lowNet=Forward(low,rules,options).MonthlyNet.Numerator;
            var highNet=Forward(high,rules,options).MonthlyNet.Numerator;
            if(target<lowNet || target>highNet) continue;
            while(low<high)
            {
                budget.Step(token); var middle=low+(high-low)/2;
                if(Forward(middle,rules,options).MonthlyNet.Numerator>=target) high=middle; else low=middle+1;
            }
            if(Forward(low,rules,options).MonthlyNet==new Rational(target,1)) return low;
        }
        throw new ArithmeticException("No whole-leu gross within the supported full-month Romanian profile produces this exact net");
    }
    internal PayrollResult Evaluate(SalaryExpression expression,SheetValue value,string origin)
    {
        var rules=GetRules(expression); var options=expression.Romanian??new();
        var dependants=options.Dependants??options.SchoolChildren;
        if(options.SchoolChildren>dependants) throw new ArithmeticException("School children must be included in the total dependant count");
        if(!options.MainJob && (dependants>0 || options.YouthRelief)) throw new ArithmeticException("Personal deductions require the main-job profile");
        if(options.BasicSalary is { } basic && (basic<rules.Minimum || basic>MaxMonthlyGross)) throw new ArithmeticException("Full-month Romanian basic salary must be at least the dated minimum and within the gross bound");
        var hadPeriod=value.Kind==SheetValueKind.Earnings;
        var period=hadPeriod?value.Earnings.Period:EarningsPeriod.Month;
        if(period is not EarningsPeriod.Month and not EarningsPeriod.Year) throw new ArithmeticException("Annualize hourly/workday earnings explicitly before applying salary rules");
        var amount=hadPeriod?value.Earnings.Amount:value;
        if(amount.Kind==SheetValueKind.Money)
        {
            var converted=money.Convert(amount.Money,"RON"); outputCurrency="RON"; stamp=converted.RateStamp; amount=new(converted.Magnitude);
        }
        var number=amount.Number;
        if(!number.IsRational || number.Unit is not null || number.IsPercentage) throw new ArithmeticException("Romanian salary requires a rational RON amount without units or percentages");
        approximate=number.IsApproximate;
        var input=period==EarningsPeriod.Year?Divide(number.Scalar,Twelve):number.Scalar;
        if(input.Denominator!=BigInteger.One || input.Numerator.Sign<0 || input.Numerator>MaxMonthlyGross)
            throw new ArithmeticException("Romanian salary currently requires whole-leu monthly amounts within the annual gross bound");
        var integer=(int)input.Numerator;
        var gross=expression.Inverse?Inverse(integer,rules,options):integer;
        if(gross<rules.Minimum || options.BasicSalary>gross) throw new ArithmeticException("Gross must cover the dated full-month minimum and the declared basic salary; partial-month/part-time profiles are unavailable");
        var monthly=Forward(gross,rules,options);
        var returned=expression.EmployerCost?monthly.EmployerCost:expression.Inverse?monthly.MonthlyGross:monthly.MonthlyNet;
        var output=Output(period==EarningsPeriod.Year?Multiply(returned,Twelve):returned);
        if(hadPeriod) output=new(new EarningsValue(output,period));
        var cas=Round(Multiply(monthly.ContributionBase,new(1,4)),true);
        var cass=Round(Multiply(monthly.ContributionBase,new(1,10)),true);
        var income=Subtract(Subtract(Subtract(monthly.MonthlyGross,cas),cass),monthly.MonthlyNet);
        PayrollDeduction[] deductions=[new("CAS employee pension",Multiply(cas,Twelve)),new("CASS employee health",Multiply(cass,Twelve)),new("Income tax",Multiply(income,Twelve))];
        var detail=$"Romanian salary {(expression.Inverse?"net to gross":"gross to net")}; RO from {origin}; {rules.Version}; payroll month {rules.Month.ToString("yyyy-MM",CultureInfo.InvariantCulture)}; full month, normal working conditions, " +
            (options.MainJob?"main job":"other job")+$"; basic salary {monthly.MonthlyBasicSalary} RON; total eligible dependants {dependants}, eligible school children claimed by this parent only {options.SchoolChildren}; "+
            (options.YouthRelief?"youth relief eligibility asserted":"no youth relief")+"; "+
            (options.MinimumRelief?"minimum-wage relief assumes full-time eligibility and no disqualifying basic-pay reduction":"minimum-wage relief disabled")+
            $"; dated minimum {rules.Minimum} RON; monthly tax-free amount {monthly.MinimumRelief} RON; contribution base {monthly.ContributionBase} RON"+
            $"; base/youth/child deductions {monthly.BaseDeduction}/{monthly.YouthDeduction}/{monthly.ChildDeduction} RON; applied deduction {monthly.AppliedDeduction} RON; taxable {monthly.TaxableIncome} RON"+
            $"; CAS {cas} RON; CASS {cass} RON; income tax {income} RON; net {monthly.MonthlyNet} RON; employer CAM {monthly.EmployerContribution} RON; employer cost {monthly.EmployerCost} RON"+
            "; contributions/deduction fields rounded to whole lei, half upward; employer CAM allocated to this employee, not multiemployee aggregate settlement; no benefits, leave, special sectors, voluntary deductions or partial-month/part-time settlement; whole-leu monthly input domain"+
            (period==EarningsPeriod.Year?"; annual output is twelve identical months under the selected month's rules, not a mixed-rule calendar-year settlement":"; bare amounts default to monthly RON model units")+
            (expression.Inverse?"; lowest whole-leu gross among all deduction/relief intervals, verified by exact forward net; other gross amounts may produce the same rounded net":"")+
            (approximate?"; upstream input is approximate":"; exact represented input")+
            (money.Provenance is { } provenance?"; "+provenance+"; generic exchange-rate conversion, not statutory BNR payroll conversion":"");
        if(expression.OutputPeriod is { } target)
        {
            var rate=hadPeriod?output:new SheetValue(new EarningsValue(output,EarningsPeriod.Month));
            var converter=new EarningsArithmetic(math,money,new WorkdayArithmetic(budget,token),context,reads,token);
            output=converter.Convert(rate,target); detail+="; "+converter.Assumption;
        }
        string[] sources=["https://static.anaf.ro/static/10/Anaf/legislatie/Cod_fiscal_norme_2023.htm",
            "https://static.anaf.ro/static/10/Anaf/legislatie/OUG_89_2025.pdf",
            "https://static.anaf.ro/static/10/Anaf/legislatie/"+(rules.Month.Month<=6?"HG_1506_2024.pdf":"HG_146_2026.pdf"),
            "https://static.anaf.ro/static/10/Anaf/Declaratii_R/AplicatiiDec/"+(rules.Month.Month<=6?"structura_D112_0126_300326.pdf":"structura_D112_0726_070926.pdf")];
        detail+="; rule sources "+string.Join("; ",sources);
        var evidence=new PayrollEvidence("RO",2026,rules.Version,Multiply(monthly.MonthlyGross,Twelve),Multiply(monthly.MonthlyNet,Twelve),
            Multiply(monthly.AppliedDeduction,Twelve),Multiply(monthly.TaxableIncome,Twelve),Array.AsReadOnly(deductions),expression.Inverse,approximate,
            "Whole-leu full-month Romanian employee model; annual fields project twelve identical selected-rule months")
            {Sources=Array.AsReadOnly(sources),Romanian=monthly};
        return new(output,detail,evidence);
    }
}
