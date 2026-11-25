namespace Calc.Core;

/// <summary>Exact monetary quantity. Decimal display rounding never replaces its authoritative magnitude.</summary>
public sealed record MoneyValue
{
    public NumericValue Magnitude { get; }
    public string Currency { get; }
    public CurrencyRateStamp? RateStamp { get; }
    public bool ExactDisplay { get; }
    public string? RateSnapshotKey => RateStamp?.Key;
    public MoneyValue(NumericValue magnitude,string currency,CurrencyRateStamp? provenance = null,bool exactDisplay = false)
    {
        if (magnitude.IsPercentage || magnitude.Unit?.IsTemperaturePoint == true) throw new ArithmeticException("Invalid money magnitude");
        Currency = CurrencyCatalog.ByCode(currency).Code; Magnitude = magnitude;
        if (provenance?.Key.Length > 64) throw new ArithmeticException("Invalid currency provenance");
        RateStamp = provenance;
        ExactDisplay = exactDisplay;
    }
    public string Display
    {
        get
        {
            var math = new ExactArithmetic(new(),default); var quantities = new QuantityArithmetic(math);
            var displayed = quantities.DisplayMagnitude(Magnitude);
            var rounded = ExactRounding.Apply(RoundingKind.DecimalPlaces,new NumericValue(displayed),new(new Rational(CurrencyCatalog.ByCode(Currency).Digits,1)),default,math);
            var number = ExactDisplay ? displayed.ToString() : rounded.Display;
            if (ExactDisplay && (!displayed.IsRational || number.Contains('/'))) number = "(" + number + ")";
            var text = (Magnitude.IsApproximate ? "≈ " : "") + number + " " + Currency + (Magnitude.Unit?.MoneySuffix() ?? "");
            if (text.Length > 2048) throw new ArithmeticException("Money output limit exceeded");
            return text;
        }
    }
    public override string ToString() => Display;
}

public sealed record CurrencyRateStamp(string Key,string Provider,DateOnly AsOf,DateTimeOffset RetrievedAt);
