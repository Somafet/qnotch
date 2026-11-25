namespace Calc.Core;

/// <summary>Exact dimensionless number or percentage ratio. Formatting is not authoritative data.</summary>
public readonly record struct NumericValue
{
    public ExactNumber Exact { get; init; }
    public UnitExpression? Unit { get; init; }
    private readonly string? quantityKind;
    public string QuantityKind { get => quantityKind ?? ""; init => quantityKind = string.IsNullOrEmpty(value) ? null : value; }
    public Rational Scalar { get => Unit is null ? Exact.Rational : throw new ArithmeticException("Expected a dimensionless value"); init => Exact = new(value); }
    public bool IsRational => Exact.IsRational;
    public bool IsPercentage { get; init; }
    public bool UseCompoundDuration { get; init; }
    public bool UseDaysInDuration { get; init; }
    /// <summary>A quantity of time, which a host may present as days, hours and minutes.</summary>
    public bool IsDuration => Unit?.Dimension == TimeArithmetic.TimeDimension;
    public bool IsApproximate { get; init; }
    /// <summary>Compact presentation of a named constant: comma groups or scientific form. Copy keeps the complete digits.</summary>
    public bool UseConstantNotation { get; init; }
    public int? DisplayDecimalPlaces { get; init; }
    public NumericValue(Rational Scalar, bool IsPercentage = false) { Exact = new(Scalar); this.IsPercentage = IsPercentage; }
    internal NumericValue(ExactNumber exact, bool isPercentage = false) { Exact = exact; IsPercentage = isPercentage; }
    internal NumericValue(ExactNumber exact, UnitExpression unit) { Exact = exact; Unit = unit; QuantityKind = unit.Kind; }
    public string Display
    {
        get
        {
            if (UseCompoundDuration && Unit?.Dimension == TimeArithmetic.TimeDimension) return (IsApproximate ? "≈ " : "") + TimeSyntax.Duration(Exact, UseDaysInDuration);
            var math = new ExactArithmetic(new(), default);
            var value = Unit is not null ? new QuantityArithmetic(math).DisplayMagnitude(this) : IsPercentage ? math.Scale(Exact, new Rational(100, 1)) : Exact;
            if (DisplayDecimalPlaces is { } places)
            {
                if (places is < 0 or > 256) throw new ArithmeticException("Invalid display precision");
                value = ExactRounding.Apply(RoundingKind.DecimalPlaces, new(value), new(new Rational(places, 1)), default, math).Exact;
            }
            var rounded = false;
            var number = UseConstantNotation ? ConstantCatalog.Notation(value, math, out rounded) : value.ToString();
            var grouped = !UseConstantNotation && (IsPercentage || Unit is not null) && (!value.IsRational || number.Contains('/'));
            var text = (IsApproximate || rounded ? "≈ " : "") + (grouped ? "(" + number + ")" : number) + (IsPercentage ? "%" : Unit is not null ? " " + Unit.Symbol : "");
            if (text.Length > 2048) throw new ArithmeticException("Output limit exceeded");
            return text;
        }
    }
    public override string ToString() => Display;
}

public sealed record CalculationStep(string Operation, IReadOnlyList<string> Operands, string Result, string? Assumption = null)
{
    public IReadOnlyList<AmortizationYear>? Schedule { get; init; }
    public IrrEvidence? Irr { get; init; }
    public GrowthEvidence? Growth { get; init; }
    public PayrollEvidence? Payroll { get; init; }
    public RomanianTaxEvidence? RomanianTax { get; init; }
    public ChemistryEvidence? Chemistry { get; init; }
    public TextTransformEvidence? TextTransform { get; init; }
}

public sealed record LineResult(int Line, SheetValue? Value, string? Error)
{
    public string Display => IsDeclaration && Error is null ? "" : Value?.Display ?? Error ?? Pending ?? "";
    /// <summary>An unrolled dice line's muted range. The line has no value until it is rolled.</summary>
    public string? Pending { get; init; }
    public bool IsDeclaration { get; init; }
    /// <summary>A sheet `sum`/`average` line: the value Share and exports offer as the sheet total.</summary>
    public bool IsAggregate { get; init; }
    public IReadOnlyList<CalculationStep> Explanation { get; init; } = [];
    public IReadOnlyList<int> Dependencies { get; init; } = [];
    /// <summary>The monetary result converted to the default display currency, when one applies. <see cref="Value"/> stays authoritative.</summary>
    public SheetValue? Shown { get; init; }
}
