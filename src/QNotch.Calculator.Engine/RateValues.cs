namespace Calc.Core;

public enum UsageKind { Items, Tokens, Requests }

public sealed record UsageCountValue
{
    public NumericValue Quantity { get; }
    public UsageKind Kind { get; }
    public string Name => Kind.ToString().ToLowerInvariant();
    public string Display => new NumericValue(Quantity.Exact.Rational / (Quantity.Unit?.Factor ?? new Rational(1,1))) { IsApproximate=Quantity.IsApproximate, DisplayDecimalPlaces=Quantity.DisplayDecimalPlaces }.Display + " " + Name + (Quantity.Unit?.MoneySuffix() ?? "");
    public string CopyText => Name + "(" + DeveloperSource.Fraction(Quantity.Exact.Rational/(Quantity.Unit?.Factor??new Rational(1,1))) + ")" + (Quantity.Unit?.MoneySuffix() ?? "");
    public string Details => "Usage kind: " + Name + "; exact canonical count" + (Quantity.Unit is null ? "" : " per second") + " = " + Quantity.Exact +
        "\nFractional counts/rates are estimates; no request, tokenization or provider is performed. Exact represented magnitude and display unit are retained.";
    internal UsageCountValue(NumericValue quantity,UsageKind kind)
    {
        if(!Enum.IsDefined(kind)||!quantity.IsRational||quantity.IsPercentage||quantity.Exact.Rational.Numerator<0||quantity.QuantityKind.Length>0||
            quantity.Unit is { } unit && unit.Dimension!=RateArithmetic.InverseTime)throw new ArithmeticException("Usage must be a nonnegative rational count or count/time rate");
        Quantity=quantity;Kind=kind;
    }
}

public sealed record UsagePriceValue
{
    public MoneyValue Amount { get; }
    public Rational PerCount { get; }
    public UsageKind? Kind { get; }
    public string Display => new MoneyValue(Amount.Magnitude,Amount.Currency,Amount.RateStamp,true).Display + "/" + (PerCount==new Rational(1_000_000,1)?"M":PerCount.ToString()) + (Kind is null?"":" "+Kind.ToString()!.ToLowerInvariant());
    public string CopyText => (Kind is UsageKind.Tokens?"tokenPrice":Kind is UsageKind.Requests?"requestPrice":Kind is UsageKind.Items?"itemPrice":"usagePrice") + "(" +
        DeveloperSource.Fraction(Amount.Magnitude.Exact.Rational)+" "+Amount.Currency+","+DeveloperSource.Fraction(PerCount)+")";
    public string Details => "Price: "+Amount.Magnitude.Exact+" "+Amount.Currency+" per "+PerCount+" "+(Kind?.ToString().ToLowerInvariant()??"items inferred from the count")+
        "\nFlat prorated arithmetic; supplied price only. No tiering, free allowance, minimum bill, tax, provider quote or actual invoice is inferred.";
    internal UsagePriceValue(MoneyValue amount,Rational perCount,UsageKind? kind)
    {
        if(amount.Magnitude.Unit is not null||!amount.Magnitude.IsRational||amount.Magnitude.Exact.Rational.Numerator<0||perCount.Numerator<=0||kind is not null&&!Enum.IsDefined(kind.Value))
            throw new ArithmeticException("Unit price requires nonnegative plain money and a positive count denominator");
        Amount=new MoneyValue(amount.Magnitude,amount.Currency,amount.RateStamp);PerCount=perCount;Kind=kind;
    }
}

public sealed record UptimeBudgetValue
{
    public Rational Availability { get; }
    public Rational IntervalSeconds { get; }
    public Rational DowntimeSeconds => (new Rational(1,1)-Availability)*IntervalSeconds;
    public bool DefaultInterval { get; }
    public string Display
    {
        get
        {
            var n=DowntimeSeconds;
            var rounded=new Rational((n.Numerator*2+n.Denominator)/(n.Denominator*2),1);
            return TimeSyntax.Duration(new(rounded),true);
        }
    }
    public string CopyText => (DefaultInterval?"uptime(":"downtime(")+"("+DeveloperSource.Fraction(Availability*new Rational(100,1))+")%"+
        (DefaultInterval?"":","+DeveloperSource.Fraction(IntervalSeconds)+" s")+")";
    public string Details => "Time-based downtime budget = (1 - "+Availability+") × "+IntervalSeconds+" s = "+DowntimeSeconds+" s"+
        (DefaultInterval?"\nDefault reporting interval: 365.25/12 days (30.4375 days), a mean-month convention.":"\nExplicit elapsed reporting interval; no calendar or request-based SLI inferred.")+
        "\nPreview rounds to the nearest whole second, halfway upward; exact duration is retained. This is a planning budget, not measured availability or an SLA guarantee.";
    internal UptimeBudgetValue(Rational availability,Rational interval,bool defaultInterval)
    {
        if(availability.Numerator<0||availability.Numerator>availability.Denominator||interval.Numerator<=0)throw new ArithmeticException("Availability must be 0–100% and reporting duration positive");
        Availability=availability;IntervalSeconds=interval;DefaultInterval=defaultInterval;
    }
}
