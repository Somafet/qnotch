namespace Calc.Core;

internal sealed class RateArithmetic(ExactArithmetic math,ExecutionBudget budget,CancellationToken token,MoneyArithmetic money)
{
    internal static readonly Dimension Data=new(0,0,0,0,0,0,0,1);
    internal static readonly Dimension DataRate=new(0,0,-1,0,0,0,0,1);
    internal static readonly Dimension InverseTime=new(0,0,-1,0,0,0,0,0);
    internal const string Convention="Exact represented rates; SI/binary and bit/byte scales retained; ideal constant payload transfer or flat prorated supplied prices; no network, billing provider or availability measurement";
    // Trace exact canonical magnitudes rather than rounded gutter text.
    internal static string Evidence(SheetValue value) => value.Kind switch
    {
        SheetValueKind.UsageCount => value.UsageCount.Details,
        SheetValueKind.UsagePrice => value.UsagePrice.Details + Stamp(value.UsagePrice.Amount),
        SheetValueKind.UptimeBudget => value.UptimeBudget.Details,
        SheetValueKind.Money => "Exact canonical money: " + value.Money.Magnitude.Exact + " " + value.Money.Currency + "; dimension " + (value.Money.Magnitude.Unit?.Dimension.ToString() ?? "dimensionless") + Stamp(value.Money),
        SheetValueKind.Number => "Exact canonical magnitude: " + value.Exact + "; dimension " + (value.Unit?.Dimension.ToString() ?? "dimensionless"),
        _ => value.Display
    };
    private static string Stamp(MoneyValue value) => value.RateStamp is { } stamp ? "\nCurrency snapshot: " + stamp.Provider + "; " + stamp.AsOf.ToString("yyyy-MM-dd",System.Globalization.CultureInfo.InvariantCulture) + "; " + stamp.Key : "";
    private readonly QuantityArithmetic quantities=new(math);
    internal static bool IsFunction(string name)=>name.ToLowerInvariant() is "transfer" or "throughput" or "uptime" or "downtime" or "tokens" or "requests" or "items" or "tokenprice" or "requestprice" or "itemprice" or "usageprice" or "usagecost" or "usagefor";
    internal static void ValidateArity(string name,int count)
    {
        var valid=name.ToLowerInvariant() switch{"tokens" or "requests" or "items"=>count==1,"uptime"=>count is 1 or 2,_=>count==2};
        if(!valid)throw new FormatException($"{name} has an invalid argument count");
    }
    private void Step()=>budget.Step(token);
    private static NumericValue Number(SheetValue value)=>value.Kind==SheetValueKind.Integer?new(new Rational(value.Integer.Value,1)):value.Number;
    private static Rational Plain(SheetValue value)
    {var n=Number(value);if(n.Unit is not null||!n.IsRational||n.IsPercentage||n.IsApproximate)throw new ArithmeticException("Expected an exact dimensionless count");return n.Exact.Rational;}
    private static Rational Seconds(SheetValue value,bool allowZero=false,bool requireExact=false)
    {
        var n=Number(value);if(n.Unit?.Dimension!=TimeArithmetic.TimeDimension||!n.IsRational||requireExact&&n.IsApproximate||n.IsPercentage||n.Exact.Rational.Numerator<0||!allowZero&&n.Exact.Rational.Numerator==0)
            throw new ArithmeticException("Expected a positive exact elapsed duration; calendar months/years require an explicit elapsed interval");
        return n.Exact.Rational;
    }
    internal SheetValue Count(SheetValue value,UsageKind kind)=>new(new UsageCountValue(Number(value),kind));
    internal SheetValue Price(SheetValue amount,Rational perCount,UsageKind? kind)=>new(new UsagePriceValue(amount.Money,perCount,kind));
    internal SheetValue Attach(UsageCountValue count,UnitExpression unit,bool conversion)=>new(new UsageCountValue(conversion?quantities.Convert(count.Quantity,unit):quantities.Attach(count.Quantity,unit),count.Kind));
    internal SheetValue ConvertCount(UsageCountValue count,UsageKind kind,UnitExpression? unit)
    {
        if(count.Kind!=kind)throw new ArithmeticException("Cannot convert tokens to requests or generic items");
        if(unit is null)return count.Quantity.Unit is null?new(count):throw new ArithmeticException("Usage rate conversion requires /time");
        return Attach(count,unit,true);
    }
    internal SheetValue Nominal(UptimeBudgetValue budget)=>new(new NumericValue(budget.DowntimeSeconds){Unit=UnitExpression.Single(UnitCatalog.ById("s")),UseCompoundDuration=true,UseDaysInDuration=true});
    internal SheetValue Transfer(SheetValue data,SheetValue rate)
    {
        Step();var size=Number(data);var speed=Number(rate);
        if(size.Unit?.Dimension!=Data||speed.Unit?.Dimension!=DataRate||!size.IsRational||!speed.IsRational||size.IsPercentage||speed.IsPercentage||size.Exact.Rational.Numerator<0||speed.Exact.Rational.Numerator<=0)
            throw new ArithmeticException("Transfer requires nonnegative data and a positive data/time speed");
        return new(quantities.Binary("/",size,speed) with{Unit=UnitExpression.Single(UnitCatalog.ById("s")),UseCompoundDuration=true,UseDaysInDuration=true});
    }
    internal SheetValue Throughput(SheetValue data,SheetValue duration)
    {
        Step();var size=Number(data);_=Seconds(duration);
        if(size.Unit?.Dimension!=Data||!size.IsRational||size.IsPercentage||size.Exact.Rational.Numerator<0)throw new ArithmeticException("Throughput requires nonnegative data");
        var unit=UnitExpression.Single(UnitCatalog.ById("MB")).Combine(UnitExpression.Single(UnitCatalog.ById("s")),-1);
        return new(quantities.Convert(quantities.Binary("/",size,Number(duration)),unit) with{DisplayDecimalPlaces=2});
    }
    internal SheetValue At(SheetValue subject,SheetValue price)
    {
        Step();
        if(price.Kind==SheetValueKind.UsagePrice)
        {
            var count=subject.Kind==SheetValueKind.UsageCount?subject.UsageCount:new UsageCountValue(Number(subject),UsageKind.Items);
            var p=price.UsagePrice;if(p.Kind is { } kind&&kind!=count.Kind)throw new ArithmeticException("Usage kind does not match the price denominator");
            var quantity=quantities.Scale(count.Quantity,new Rational(1,1)/p.PerCount);
            var result=money.Binary("*",new(p.Amount),new(quantity)).Money;
            return new(new MoneyValue(result.Magnitude,result.Currency,result.RateStamp));
        }
        if(subject.Kind==SheetValueKind.Number&&price.Kind==SheetValueKind.Number&&subject.Unit?.Dimension==Data&&price.Unit?.Dimension==DataRate)return Transfer(subject,price);
        if(subject.Kind==SheetValueKind.Number&&price.Kind==SheetValueKind.Money&&price.Money.Magnitude.Unit is not null)
        {
            var amount=Number(subject);var p=price.Money;
            if(math.Sign(amount.Exact)<0||math.Sign(p.Magnitude.Exact)<0)throw new ArithmeticException("Flat billing inputs cannot be negative");
            var result=money.Binary("*",price,subject).Money;
            if(result.Magnitude.Unit is not null)throw new ArithmeticException("Price denominator does not cancel the supplied quantity");
            return new(new MoneyValue(result.Magnitude,result.Currency,result.RateStamp));
        }
        throw new ArithmeticException("Expected data at a transfer speed, or a count/quantity at its unit price");
    }
    internal SheetValue For(SheetValue rate,SheetValue duration)
    {
        Step();_=Seconds(duration,true);
        if(rate.Kind==SheetValueKind.Money&&rate.Money.Magnitude.Unit?.Dimension==InverseTime)
        {
            if(math.Sign(rate.Money.Magnitude.Exact)<0)throw new ArithmeticException("Billing rate cannot be negative");
            var result=money.Binary("*",rate,duration).Money;return new(new MoneyValue(result.Magnitude,result.Currency,result.RateStamp));
        }
        if(rate.Kind==SheetValueKind.UsageCount&&rate.UsageCount.Quantity.Unit?.Dimension==InverseTime)return Binary("*",rate,duration);
        if(rate.Kind==SheetValueKind.Number&&rate.Unit?.Dimension==DataRate)
        {if(!rate.IsRational||rate.Exact.Rational.Numerator<0)throw new ArithmeticException("Data rate must be nonnegative rational");return quantities.Binary("*",rate.Number,Number(duration));}
        throw new ArithmeticException("for requires an elapsed-time rate; calendar earnings are separate");
    }
    internal SheetValue Binary(string op,SheetValue left,SheetValue right)
    {
        Step();
        if(left.Kind==SheetValueKind.Money&&right.Kind==SheetValueKind.UsagePrice&&op=="/")
        {var p=right.UsagePrice;var ratio=money.Binary("/",left,new(p.Amount));return new(new UsageCountValue(quantities.Scale(ratio.Number,p.PerCount),p.Kind??UsageKind.Items));}
        if(left.Kind==SheetValueKind.UsagePrice&&right.Kind==SheetValueKind.UsagePrice)
        {
            var a=left.UsagePrice;var b=right.UsagePrice;if(a.Kind!=b.Kind)throw new ArithmeticException("Price kinds must match");
            var normalized=new MoneyValue(quantities.Scale(b.Amount.Magnitude,a.PerCount/b.PerCount),b.Amount.Currency,b.Amount.RateStamp);
            if(op is not ("+" or "-"))throw new ArithmeticException("Unit prices support matching addition/subtraction or numeric scaling");
            return new(new UsagePriceValue(money.Binary(op,new(a.Amount),new(normalized)).Money,a.PerCount,a.Kind));
        }
        if(left.Kind==SheetValueKind.UsagePrice||right.Kind==SheetValueKind.UsagePrice)
        {
            var price=left.Kind==SheetValueKind.UsagePrice?left.UsagePrice:right.UsagePrice;var other=left.Kind==SheetValueKind.UsagePrice?right:left;
            if(other.Kind==SheetValueKind.UsageCount&&op is "*" or "of")return At(other,new(price));
            if(other.Kind is SheetValueKind.Number or SheetValueKind.Integer && op is "*" or "/" or "of" && (op!="/"||left.Kind==SheetValueKind.UsagePrice))
            {
                var n=Number(other);if(n.Unit is not null||n.IsPercentage)throw new ArithmeticException("Unit-price scaling requires an ordinary scalar");
                return new(new UsagePriceValue(money.Binary(op,new(price.Amount),new(n)).Money,price.PerCount,price.Kind));
            }
            throw new ArithmeticException("Unsupported unit-price arithmetic");
        }
        if(left.Kind==SheetValueKind.UsageCount&&right.Kind==SheetValueKind.UsageCount)
        {
            var a=left.UsageCount;var b=right.UsageCount;if(a.Kind!=b.Kind)throw new ArithmeticException("Cannot mix token and request counts");
            var result=quantities.Binary(op,a.Quantity,b.Quantity);
            return op=="/"?new(result):op is "+" or "-"?new(new UsageCountValue(result,a.Kind)):throw new ArithmeticException("Products of counts are unsupported");
        }
        if(left.Kind!=SheetValueKind.UsageCount&&right.Kind!=SheetValueKind.UsageCount)throw new ArithmeticException("Unsupported unit-price arithmetic");
        var count=left.Kind==SheetValueKind.UsageCount?left.UsageCount:right.UsageCount;var numeric=Number(left.Kind==SheetValueKind.UsageCount?right:left);
        if(numeric.IsPercentage&&op is "+" or "-"&&left.Kind==SheetValueKind.UsageCount)return new(new UsageCountValue(quantities.Binary(op,count.Quantity,numeric),count.Kind));
        if(op is not ("*" or "/" or "of")||op=="/"&&left.Kind!=SheetValueKind.UsageCount)throw new ArithmeticException("Counts require matching counts or numeric scaling");
        return new(new UsageCountValue(quantities.Binary(op,count.Quantity,numeric),count.Kind));
    }
    internal SheetValue Unary(string op,SheetValue value)
    {
        if(op is not ("+" or "-"))throw new ArithmeticException("Unsupported count/price unary operation");
        if(value.Kind==SheetValueKind.UsageCount)return new(new UsageCountValue(quantities.Unary(op,value.UsageCount.Quantity),value.UsageCount.Kind));
        var p=value.UsagePrice;return new(new UsagePriceValue(money.Unary(op,p.Amount),p.PerCount,p.Kind));
    }
    internal SheetValue Aggregate(IReadOnlyList<SheetValue> values,bool average)
    {
        if(values.Count==0)throw new ArithmeticException("No usage values to aggregate");
        var sum=values[0];for(var i=1;i<values.Count;i++)sum=Binary("+",sum,values[i]);
        return average?Binary("/",sum,new(new Rational(values.Count,1))):sum;
    }
    internal SheetValue Round(RoundingKind kind,SheetValue value,SheetValue precision)
    {
        if(value.Kind==SheetValueKind.UsageCount)
        {
            var count=value.UsageCount;var quantum=precision.Kind==SheetValueKind.UsageCount?
                precision.UsageCount.Kind==count.Kind?precision.UsageCount.Quantity:throw new ArithmeticException("Count rounding kind mismatch"):Number(precision);
            return new(new UsageCountValue(quantities.Round(kind,count.Quantity,quantum,token),count.Kind));
        }
        var p=value.UsagePrice;return new(new UsagePriceValue(money.Round(kind,p.Amount,precision,token),p.PerCount,p.Kind));
    }
    internal SheetValue Function(string name,SheetValue[] args)
    {
        Step();ValidateArity(name,args.Length);var key=name.ToLowerInvariant();
        if(key is "tokens" or "requests" or "items")return Count(args[0],key=="tokens"?UsageKind.Tokens:key=="requests"?UsageKind.Requests:UsageKind.Items);
        if(key.EndsWith("price",StringComparison.Ordinal))return Price(args[0],Plain(args[1]),key=="tokenprice"?UsageKind.Tokens:key=="requestprice"?UsageKind.Requests:key=="itemprice"?UsageKind.Items:null);
        if(key=="transfer")return Transfer(args[0],args[1]);if(key=="throughput")return Throughput(args[0],args[1]);
        if(key=="usagecost")return At(args[0],args[1]);if(key=="usagefor")return For(args[0],args[1]);
        var availability=Number(args[0]);if(!availability.IsPercentage||!availability.IsRational||availability.IsApproximate)throw new ArithmeticException("Uptime target requires an exact percentage");
        var defaultInterval=args.Length==1;var seconds=defaultInterval?new Rational(36525*86400L,1200):Seconds(args[1],requireExact:true);
        return new(new UptimeBudgetValue(availability.Exact.Rational,seconds,defaultInterval));
    }
}
