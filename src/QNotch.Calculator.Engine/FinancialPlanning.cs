using System.Numerics;

namespace Calc.Core;

public sealed record GrowthEvidence(Rational Years, Rational PoweredRatio, int RootDegree, IrrEvidence? Root);

internal sealed partial class FinancialArithmetic
{
    private static bool IsPlanningFunction(string name) => name.ToLowerInvariant() is "cagr" or "roi" or "realreturn" or "fire" or "breakeven" or "sln" or "ddb" or "syd";
    private static void ValidatePlanningArity(string name,int count)
    {
        var (minimum,maximum)=name.ToLowerInvariant() switch
        { "roi" or "realreturn" => (2,2), "fire" => (1,2), "ddb" => (4,5), "syd" => (4,4), _ => (3,3) };
        if(count<minimum || count>maximum) throw new FormatException($"{name} expects {minimum}–{maximum} arguments");
    }
    private static void Nonnegative(Rational value,string input)
    { if(value.Numerator.Sign<0) throw new ArithmeticException(input+" must be nonnegative"); }
    private string PlanningAssumption(string detail) => detail+"; represented amounts retained; display rounding is separate; "+
        (approximate?"upstream input or bounded financial arithmetic is approximate":"exact represented inputs")+(money.Provenance is { } source?"; "+source:"");
    internal FinancialResult PlanningSentence(PlanningSentenceExpression expression,SheetValue[] args)
    {
        if(expression.AnnualScale!=1)
        {
            args=(SheetValue[])args.Clone();
            SetTemplate(args.Take(1)); var annual=Multiply(Cash(args[0]),new(expression.AnnualScale,1));
            args[0]=Output(annual);
        }
        var result=PlanningFunction(expression.Name,args);
        return result with{Assumption=result.Assumption+(expression.Name=="fire"?"; source spending per "+expression.Period+", annualized by "+expression.AnnualScale:"; straight-line charge per "+expression.Period)};
    }
    private SheetValue Percent(Rational value) => new(new NumericValue(value,true){IsApproximate=approximate,DisplayDecimalPlaces=4});
    private int Months(SheetValue value)
    {
        if(value.Kind==SheetValueKind.CalendarPeriod)
        {
            if(value.Period.Days!=0 || value.Period.Months is <1 or >1200) throw new ArithmeticException("Growth term must contain 1–1200 whole calendar months");
            return value.Period.Months;
        }
        var years=Plain(value); var months=Multiply(years,new(12,1));
        if(value.Number.IsApproximate || months.Denominator!=1 || months.Numerator<1 || months.Numerator>1200)
            throw new ArithmeticException("Growth years must resolve to 1–1200 exact whole months");
        return (int)months.Numerator;
    }
    private Rational Power(Rational value,int exponent)
    {
        var result=One;
        while(exponent>0)
        { budget.Step(token); if((exponent&1)!=0) result=Multiply(result,value); exponent>>=1; if(exponent>0) value=Multiply(value,value); }
        return result;
    }
    private BigInteger IntegerRoot(BigInteger value,int degree)
    {
        if(value<=1 || degree==1) return value;
        var lower=BigInteger.Zero; var upper=BigInteger.One << (int)((value.GetBitLength()+degree-1)/degree);
        while(upper-lower>1)
        {
            budget.Step(token); var middle=(lower+upper)/2;
            if(ComparePower(middle,degree,value)<=0) lower=middle; else upper=middle;
        }
        return ComparePower(upper,degree,value)==0?upper:lower;
    }
    private int ComparePower(BigInteger value,int exponent,BigInteger target)
    {
        var result=BigInteger.One;
        while(exponent>0)
        {
            budget.Step(token);
            if((exponent&1)!=0) { result*=value; if(result>target) return 1; }
            exponent>>=1;
            if(exponent>0) { value*=value; if(value>target) value=target+1; }
        }
        return result.CompareTo(target);
    }
    private FinancialResult PlanningFunction(string name,SheetValue[] args)
    {
        var key=name.ToLowerInvariant();
        if(key=="realreturn")
        {
            var nominal=Plain(args[0],true); var inflation=Rate(args[1]);
            if(nominal.Numerator < -nominal.Denominator) throw new ArithmeticException("Nominal return must be at least -100%");
            var result=Subtract(Divide(Add(One,nominal),Add(One,inflation)),One);
            return new(Percent(result),PlanningAssumption("Real return = (1 + nominal return) / (1 + inflation) - 1; both inputs describe the same period; no simple percentage subtraction"));
        }
        if(key=="fire")
        {
            SetTemplate(args.Take(1)); var spending=Cash(args[0]); Nonnegative(spending,"Annual spending");
            var withdrawal=args.Length==2?Plain(args[1],true):new Rational(1,25);
            if(withdrawal.Numerator.Sign<=0 || withdrawal.Numerator>withdrawal.Denominator) throw new ArithmeticException("Withdrawal rate must be greater than 0% and at most 100%");
            var target=Divide(spending,withdrawal);
            return new(Output(target),PlanningAssumption("FIRE target = annual spending / chosen withdrawal rate; rate "+new NumericValue(withdrawal,true).Display+
                (args.Length==1?" (default model assumption)":" (explicit)")+"; fixed arithmetic target, no portfolio path or withdrawal guarantee"));
        }
        if(key is "roi" or "cagr")
        {
            SetTemplate(args.Take(2)); var start=Cash(args[0]); var end=Cash(args[1]);
            if(start.Numerator.Sign<=0) throw new ArithmeticException("Initial value must be positive");
            Nonnegative(end,"Ending value"); var ratio=Divide(end,start);
            if(key=="roi") return new(Percent(Subtract(ratio,One)),PlanningAssumption("ROI = (ending value - initial value) / initial value; endpoint total return, not annualized; include desired income in ending value explicitly"));
            var months=Months(args[2]); var years=new Rational(months,12); var degree=(int)years.Numerator; var power=(int)years.Denominator;
            var powered=Power(ratio,power); var evidence=new GrowthEvidence(years,powered,degree,null);
            var assumption="CAGR = (ending / initial)^(1 / years) - 1; "+years+" calendar years; endpoint compound growth with no intermediate deposits/withdrawals; annualized";
            if(end.Numerator.IsZero) return new(Percent(new(-1,1)),PlanningAssumption(assumption+"; total loss")){Growth=evidence};
            var numerator=IntegerRoot(powered.Numerator,degree); var denominator=IntegerRoot(powered.Denominator,degree);
            if(ComparePower(numerator,degree,powered.Numerator)==0 && ComparePower(denominator,degree,powered.Denominator)==0)
                return new(Percent(Subtract(new(numerator,denominator),One)),PlanningAssumption(assumption+"; verified exact rational root")){Growth=evidence};
            if(degree==2)
            {
                var math=new ExactArithmetic(budget,token); var root=math.SquareRoot(new(powered)); var exact=math.Subtract(root,ExactArithmetic.One);
                return new(new SheetValue(new NumericValue(exact,true){IsApproximate=approximate,DisplayDecimalPlaces=4}),PlanningAssumption(assumption+"; exact real square root retained")){Growth=evidence};
            }
            var cash=new Rational[degree+1]; cash[0]=new(-1,1); cash[^1]=powered;
            var solved=new IrrSolver(budget,token).Solve(cash,new(1,10)); var rootEvidence=solved.Evidence with{InputApproximate=approximate};
            evidence=evidence with{Root=rootEvidence};
            var selected=rootEvidence.Roots[0];
            var value=new NumericValue(solved.Rate,true){IsApproximate=approximate || !selected.Exact,DisplayDecimalPlaces=4};
            return new(new SheetValue(value),PlanningAssumption(assumption+"; positive accumulation factor isolated with certified represented-rate interval and stable four-decimal percentage display; "+rootEvidence.Method)){Growth=evidence};
        }
        if(key=="breakeven")
        {
            SetTemplate(args); var fixedCost=Cash(args[0]); var price=Cash(args[1]); var cost=Cash(args[2]);
            Nonnegative(fixedCost,"Fixed cost"); Nonnegative(price,"Unit price"); Nonnegative(cost,"Unit variable cost");
            var margin=Subtract(price,cost);
            if(!fixedCost.Numerator.IsZero && margin.Numerator.Sign<=0) throw new ArithmeticException("No finite positive-volume break-even with nonpositive unit contribution");
            var units=fixedCost.Numerator.IsZero?default:Divide(fixedCost,margin);
            var whole=BigInteger.DivRem(units.Numerator,units.Denominator,out var remainder); if(!remainder.IsZero) whole++;
            return new(new SheetValue(new NumericValue(units){IsApproximate=approximate,DisplayDecimalPlaces=4}),PlanningAssumption("Break-even units = fixed cost / (unit price - unit variable cost); continuous quantity retained; whole-unit coverage threshold "+whole+"; matching cost period and constant unit economics assumed"));
        }
        SetTemplate(args.Take(2)); var initial=Cash(args[0]); var salvage=Cash(args[1]);
        Nonnegative(initial,"Asset cost"); Nonnegative(salvage,"Salvage value");
        var basis=Subtract(initial,salvage);
        if(basis.Numerator.Sign<0) throw new ArithmeticException("Salvage value cannot exceed asset cost");
        if(key=="sln")
        {
            var life=Plain(args[2]);
            if(life.Numerator.Sign<=0 || life.Numerator>1200*life.Denominator || args[2].Number.IsApproximate) throw new ArithmeticException("SLN useful life must be an exact positive value at most 1200 periods");
            var result=Divide(basis,life);
            return new(Output(result),PlanningAssumption("Straight-line charge = (cost - salvage) / useful life; amount per stated life period; no jurisdictional tax schedule inferred"));
        }
        var periods=Periods(args[2],false); var period=Periods(args[3],false);
        if(period>periods) throw new ArithmeticException("Depreciation period cannot exceed useful life");
        if(key=="syd")
        {
            var charge=Multiply(basis,new Rational(2L*(periods-period+1),(long)periods*(periods+1)));
            return new(Output(charge),PlanningAssumption("SYD charge = (cost - salvage) * (life - period + 1) / (life*(life+1)/2); period "+period+" of "+periods+"; no jurisdictional tax schedule inferred"));
        }
        var factor=args.Length==5?Plain(args[4]):new Rational(2,1);
        if(factor.Numerator.Sign<=0) throw new ArithmeticException("Declining-balance factor must be positive");
        var rate=Divide(factor,new(periods,1)); var balance=initial; var expense=default(Rational); var opening=initial;
        for(var index=1;index<=period;index++)
        {
            budget.Step(token); opening=balance;
            var available=Subtract(balance,salvage); var candidate=Multiply(balance,rate);
            if(available.Numerator.Sign<=0) { expense=default; balance=salvage; }
            else
            {
                expense=Subtract(candidate,available).Numerator.Sign>0?available:candidate;
                balance=Subtract(balance,expense);
            }
        }
        return new(Output(expense),PlanningAssumption("Declining-balance charge capped at remaining cost above salvage; factor "+factor+", period "+period+" of "+periods+
            "; opening book value "+Output(opening).Display+", closing book value "+Output(balance).Display+"; no automatic straight-line switch or final-year catch-up; no tax schedule inferred"));
    }
}
