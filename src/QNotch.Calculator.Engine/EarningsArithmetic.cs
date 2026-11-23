namespace Calc.Core;

internal sealed class EarningsArithmetic(ExactArithmetic math,MoneyArithmetic money,WorkdayArithmetic workdays,
    EvaluationContext context,ContextReads reads,CancellationToken token)
{
    private readonly QuantityArithmetic quantities=new(math);
    private static UnitExpression Per(string unit) => UnitExpression.Single(UnitCatalog.ById(unit)).Power(new(-1,1));
    internal string? Assumption { get; private set; }
    private SheetValue ScaleAmount(SheetValue amount,Rational factor) => amount.Kind==SheetValueKind.Money ?
        new(new MoneyValue(quantities.Scale(amount.Money.Magnitude,factor),amount.Money.Currency,amount.Money.RateStamp,amount.Money.ExactDisplay)) :
        new(quantities.Scale(amount.Number,factor) with{DisplayDecimalPlaces=4});
    private SheetValue AmountBinary(string operation,SheetValue left,SheetValue right) =>
        left.Kind==SheetValueKind.Money || right.Kind==SheetValueKind.Money ? money.Binary(operation,left,right) : quantities.Binary(operation,left.Number,right.Number);
    internal EarningsValue Read(SheetValue value)
    {
        if(value.Kind==SheetValueKind.Earnings) return value.Earnings;
        var numeric=value.Kind==SheetValueKind.Money?value.Money.Magnitude:value.Number;
        var period=numeric.Unit?.Equals(Per("h"))==true?EarningsPeriod.Hour:numeric.Unit?.Equals(Per("day"))==true?EarningsPeriod.Day:
            throw new ArithmeticException("Expected an hourly/daily rate or a calendar earnings rate");
        var displayed=quantities.DisplayMagnitude(numeric);
        var number=numeric with{Exact=displayed,Unit=null,QuantityKind="",UseCompoundDuration=false,UseDaysInDuration=false};
        return new(value.Kind==SheetValueKind.Money?new(new MoneyValue(number,value.Money.Currency,value.Money.RateStamp,value.Money.ExactDisplay)):new(number),period);
    }
    private Rational Factor(EarningsPeriod from,EarningsPeriod to)
    {
        Assumption ??= "Earnings periods; 12 equal monthly amounts per year; 8 hours per working day; no leave, overtime, taxes or billable-utilization adjustment";
        if(from==to) return new(1,1);
        var fromCalendar=from is EarningsPeriod.Month or EarningsPeriod.Year;
        var toCalendar=to is EarningsPeriod.Month or EarningsPeriod.Year;
        if(fromCalendar && toCalendar) return from==EarningsPeriod.Month?new(12,1):new(1,12);
        if(!fromCalendar && !toCalendar) return from==EarningsPeriod.Hour?new(8,1):new(1,8);
        reads.Dependencies |= ContextDependency.Date | ContextDependency.WorkdayCalendar;
        var year=context.RequireToday().Year; var calendar=new WorkdayCalendar(context.WorkdayRegion,context.CustomHolidays);
        var days=workdays.Between(new(year,1,1),new(year,12,31),calendar).Scalar;
        if(days.Numerator.Sign<=0) throw new ArithmeticException("No working days available in the selected earnings year");
        Assumption+="; context year "+year+"; "+days+" working days; "+calendar.Scope+"; rules "+WorkdayCalendar.RuleVersion+"; custom holidays included; current-rule projection; no days-per-month approximation";
        Rational AnnualUnits(EarningsPeriod period) => period switch { EarningsPeriod.Hour=>days*new Rational(8,1),EarningsPeriod.Day=>days,EarningsPeriod.Month=>new(12,1),_=>new(1,1) };
        return AnnualUnits(from)/AnnualUnits(to);
    }
    internal SheetValue Convert(SheetValue value,EarningsPeriod target)
    { var source=Read(value); return new(new EarningsValue(ScaleAmount(source.Amount,Factor(source.Period,target)),target)); }
    internal SheetValue Currency(SheetValue source,string currency,MoneyArithmetic converter,bool attach=false)
    {
        var rate=source.Earnings; var amount=rate.Amount;
        var converted=attach?converter.Attach(amount,currency):converter.Convert(amount.Money,currency);
        return new(new EarningsValue(new(converted),rate.Period));
    }
    internal SheetValue Unary(string operation,SheetValue value)
    {
        var rate=value.Earnings;
        if(operation is not "+" and not "-") throw new ArithmeticException("Unsupported earnings unary operation");
        return new(new EarningsValue(ScaleAmount(rate.Amount,new(operation=="-"?-1:1,1)),rate.Period));
    }
    internal SheetValue Binary(string operation,SheetValue left,SheetValue right)
    {
        var leftRate=left.Kind==SheetValueKind.Earnings;
        var rate=(leftRate?left:right).Earnings; var other=leftRate?right:left;
        if(other.Kind==SheetValueKind.Earnings)
        {
            RequireSameFamily(rate.Period,other.Earnings.Period);
            var converted=Convert(other,rate.Period).Earnings.Amount;
            if(operation is "+" or "-") return new(new EarningsValue(AmountBinary(operation,leftRate?rate.Amount:converted,leftRate?converted:rate.Amount),rate.Period));
            if(operation=="/") return AmountBinary("/",leftRate?rate.Amount:converted,leftRate?converted:rate.Amount);
            throw new ArithmeticException("Earnings rates cannot be multiplied");
        }
        if(other.Kind==SheetValueKind.CalendarPeriod && operation=="*")
        {
            if(rate.Period is not EarningsPeriod.Month and not EarningsPeriod.Year || other.Period.Days!=0) throw new ArithmeticException("Calendar earnings multiplication requires whole calendar months and a monthly/yearly rate");
            return ScaleAmount(rate.Amount,new(other.Period.Months,rate.Period==EarningsPeriod.Year?12:1));
        }
        if(other.Kind!=SheetValueKind.Number) throw new ArithmeticException("Earnings arithmetic requires compatible rates, scalar scaling or a matching duration");
        var number=other.Number;
        if(number.Unit is not null)
        {
            if(operation!="*" || number.Unit.Dimension!=TimeArithmetic.TimeDimension || rate.Period is not EarningsPeriod.Hour and not EarningsPeriod.Day)
                throw new ArithmeticException("Use calendar periods for monthly/yearly earnings; hours/days require a worked duration");
            var divisor=rate.Period==EarningsPeriod.Hour?3600:28800;
            var duration=number with{Exact=math.Scale(number.Exact,new(1,divisor)),Unit=null,QuantityKind="",UseCompoundDuration=false,UseDaysInDuration=false};
            return AmountBinary("*",rate.Amount,new(duration));
        }
        if(operation is "+" or "-" && leftRate && number.IsPercentage) return new(new EarningsValue(AmountBinary(operation,rate.Amount,other),rate.Period));
        if(operation=="*" || operation=="of" || operation=="/" && leftRate) return new(new EarningsValue(AmountBinary(operation,rate.Amount,other),rate.Period));
        throw new ArithmeticException("Do not add bare amounts to earnings rates or divide by a rate");
    }
    internal SheetValue Round(RoundingKind kind,SheetValue value,SheetValue precision)
    {
        var rate=value.Earnings;
        if(precision.Kind==SheetValueKind.Earnings) { RequireSameFamily(rate.Period,precision.Earnings.Period); precision=Convert(precision,rate.Period).Earnings.Amount; }
        var rounded=rate.Amount.Kind==SheetValueKind.Money?new SheetValue(money.Round(kind,rate.Amount.Money,precision,token)):
            new(quantities.Round(kind,rate.Amount.Number,precision.Number,token));
        return new(new EarningsValue(rounded,rate.Period));
    }
    internal SheetValue Aggregate(IReadOnlyList<SheetValue> values,bool average)
    {
        if(values.Count==0 || values.Any(value=>value.Kind!=SheetValueKind.Earnings)) throw new ArithmeticException("Aggregate earnings rates separately from amounts and other quantities");
        var period=values[0].Earnings.Period; var amounts=new List<SheetValue>();
        foreach(var value in values) { token.ThrowIfCancellationRequested(); RequireSameFamily(period,value.Earnings.Period); amounts.Add(Convert(value,period).Earnings.Amount); }
        var result=amounts.Any(value=>value.Kind==SheetValueKind.Money)?new SheetValue(money.Aggregate(amounts,average,token)):
            new(quantities.Aggregate(amounts.Select(value=>value.Number).ToArray(),average,token));
        return new(new EarningsValue(result,period));
    }
    private static void RequireSameFamily(EarningsPeriod first,EarningsPeriod second)
    {
        if((first is EarningsPeriod.Month or EarningsPeriod.Year)!=(second is EarningsPeriod.Month or EarningsPeriod.Year))
            throw new ArithmeticException("Convert calendar and hourly/daily earnings explicitly to one period before combining or aggregating");
    }
}
