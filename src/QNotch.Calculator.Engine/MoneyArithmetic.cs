namespace Calc.Core;

internal sealed class MoneyArithmetic(ExactArithmetic math,EvaluationContext context,ContextReads reads)
{
    private readonly QuantityArithmetic quantities = new(math);
    internal string? Provenance { get; private set; }
    private CurrencyRateSnapshot Snapshot()
    {
        reads.Dependencies |= ContextDependency.CurrencyRates | ContextDependency.Date;
        reads.CurrencyRequests.Add(context.CurrencyDate);
        if (reads.CurrencyRequests.Count > CurrencyRateBook.MaxHistoricalSnapshots + 1) throw new ArithmeticException("Currency request limit exceeded");
        if (context.CurrencyDate is { } requestedDate && context.Today is { } currentDate && requestedDate > currentDate) throw new ArithmeticException("Future historical currency rates are unavailable");
        var snapshot = (context.CurrencyRates ?? CurrencyRateBook.Empty).Require(context.CurrencyDate);
        if (context.CurrencyDate is null && context.Today is { } nowDate && snapshot.AsOf > nowDate) throw new ArithmeticException("Currency snapshot is dated after the current context date");
        var age = context.Today is { } today ? today.DayNumber - snapshot.AsOf.DayNumber : (int?)null;
        var monthly = snapshot.IsMonthly;
        Provenance = snapshot.Provider + (monthly ? "; cached monthly accounting rates for the month from " : "; cached daily reference rates as of ") + snapshot.AsOf.ToString("yyyy-MM-dd") + "; retrieved " + snapshot.RetrievedAt.ToString("O") +
            (context.CurrencyDate is { } requested ? "; requested " + requested.ToString("yyyy-MM-dd") + (requested == snapshot.AsOf ? "" : monthly ? "; monthly rate in force" : "; previous published business date") :
                age is null ? "; age unavailable" : age > (monthly ? 35 : 3) ? "; STALE" : monthly ? "; monthly data, not live" : "; daily data, not live") +
            "; exact cross-rate arithmetic; displayed amounts rounded, source values retained";
        return snapshot;
    }
    private static CurrencyRateStamp? Merge(MoneyValue a,MoneyValue b)
    {
        if (a.RateSnapshotKey is not null && b.RateSnapshotKey is not null && a.RateSnapshotKey != b.RateSnapshotKey)
            throw new ArithmeticException("Monetary values use different rate snapshots; evaluate them under one date");
        return a.RateStamp ?? b.RateStamp;
    }
    internal MoneyValue Attach(SheetValue value,string currency) => new(value.Number,currency);
    internal MoneyValue Convert(MoneyValue value,string currency,UnitExpression? unit = null)
    {
        var amount = value.Magnitude; var provenance = value.RateStamp;
        if (currency != value.Currency || context.CurrencyDate is not null && provenance is not null)
        {
            var snapshot = Snapshot();
            if (provenance is not null && provenance.Key != snapshot.Key) throw new ArithmeticException("Monetary value was converted with another rate date; put the original expression inside the dated conversion");
            amount = quantities.Scale(amount,snapshot.CrossRate(value.Currency,currency));
            provenance = new(snapshot.Key,snapshot.Provider,snapshot.AsOf,snapshot.RetrievedAt);
        }
        if (unit is not null) amount = quantities.Convert(amount,unit);
        return new(amount,currency,provenance,value.ExactDisplay);
    }
    internal MoneyValue AttachUnit(MoneyValue value,UnitExpression unit)
        => new(quantities.Binary("*",value.Magnitude,quantities.Attach(new(new Rational(1,1)),unit)),value.Currency,value.RateStamp,value.ExactDisplay);
    internal MoneyValue ConvertUnit(MoneyValue value,UnitExpression unit)
        => new(quantities.Convert(value.Magnitude,unit),value.Currency,value.RateStamp,value.ExactDisplay);
    internal MoneyValue Unary(string operation,MoneyValue value)
    {
        if (operation is not "+" and not "-") throw new ArithmeticException("Money cannot use a percentage, factorial or other numeric unary operator");
        return new(quantities.Unary(operation,value.Magnitude),value.Currency,value.RateStamp,value.ExactDisplay);
    }
    internal SheetValue Binary(string operation,SheetValue left,SheetValue right)
    {
        if (left.Kind == SheetValueKind.Money && right.Kind == SheetValueKind.Money)
        {
            var a = left.Money; var b = Convert(right.Money,a.Currency); var provenance = Merge(a,b);
            if (operation is "+" or "-") return new(new MoneyValue(quantities.Binary(operation,a.Magnitude,b.Magnitude),a.Currency,provenance,a.ExactDisplay||b.ExactDisplay));
            if (operation == "/") return quantities.Binary(operation,a.Magnitude,b.Magnitude);
            throw new ArithmeticException("Money products/powers are not supported; divide monetary quantities for a ratio");
        }
        var money = left.Kind == SheetValueKind.Money ? left.Money : right.Money;
        var numeric = left.Kind == SheetValueKind.Money ? right.Number : left.Number;
        if (left.Kind == SheetValueKind.Money && operation is "+" or "-" && numeric.IsPercentage)
            return new(new MoneyValue(quantities.Binary(operation,money.Magnitude,numeric),money.Currency,money.RateStamp,money.ExactDisplay));
        if (operation is "*" or "of" || operation == "/" && left.Kind == SheetValueKind.Money)
            return new(new MoneyValue(left.Kind == SheetValueKind.Money ? quantities.Binary(operation,money.Magnitude,numeric) : quantities.Binary(operation,numeric,money.Magnitude),money.Currency,money.RateStamp,money.ExactDisplay));
        throw new ArithmeticException("Money requires another monetary value or a scalar/physical rate; bare-number addition is not defined");
    }
    internal SheetValue Function(string name,SheetValue[] args)
    {
        if (args.Length == 0 || args[0].Kind != SheetValueKind.Money) throw new ArithmeticException("Expected a monetary first argument");
        var a = args[0].Money; var key = name.ToLowerInvariant();
        if (key == "abs" && args.Length == 1) return new(new MoneyValue(quantities.Function(key,[a.Magnitude]),a.Currency,a.RateStamp,a.ExactDisplay));
        if (key is "whole" or "beforediscount" && args.Length == 2)
            return new(new MoneyValue(quantities.Function(key,[a.Magnitude,args[1].Number]),a.Currency,a.RateStamp,a.ExactDisplay));
        if (key is "share" or "change" or "markup" or "margin" && args.Length == 2)
        {
            var b = Convert(args[1].Money,a.Currency); _ = Merge(a,b);
            return quantities.Function(key,[a.Magnitude,b.Magnitude]);
        }
        throw new ArithmeticException("Unsupported monetary function");
    }
    internal MoneyValue Aggregate(IReadOnlyList<SheetValue> values,bool average,CancellationToken token)
    {
        if (values.Count == 0) throw new ArithmeticException("No monetary values to aggregate");
        var first = values[0].Money; var converted = new List<NumericValue>(); var provenance = first.RateStamp;
        foreach (var item in values)
        {
            token.ThrowIfCancellationRequested(); var value = Convert(item.Money,first.Currency);
            provenance = Merge(new(first.Magnitude,first.Currency,provenance),value); converted.Add(value.Magnitude);
        }
        return new(quantities.Aggregate(converted,average,token),first.Currency,provenance,values.Any(value=>value.Money.ExactDisplay));
    }
    internal MoneyValue Round(RoundingKind kind,MoneyValue value,SheetValue precision,CancellationToken token)
    {
        NumericValue quantum;
        var provenance = value.RateStamp;
        if (kind == RoundingKind.Increment && precision.Kind == SheetValueKind.Money)
        {
            var converted = Convert(precision.Money,value.Currency); provenance = Merge(value,converted); quantum = converted.Magnitude;
        }
        else quantum = precision.Number;
        return new(quantities.Round(kind,value.Magnitude,quantum,token),value.Currency,provenance,true);
    }
}
