using System.Globalization;

namespace Calc.Core;

public enum SheetValueKind { Number, Date, CalendarPeriod, Time, LocalTimestamp, ZonedMoment, WorkdayPeriod, HolidayList, Money, List, Earnings, Matrix, Resistor, Engineering, Integer, Network, Text, Colour, Permission, Aspect, Unicode, UsageCount, UsagePrice, UptimeBudget, Equation, Complex, Prime, Practical, Plot, Chart, Table }
public readonly record struct CalendarPeriod(int Months, int Days)
{
    internal CalendarPeriod Checked()
    {
        if (Math.Abs((long)Months) > 120000 || Math.Abs((long)Days) > 3660000) throw new ArithmeticException("Calendar period limit exceeded");
        return this;
    }
    public override string ToString()
    {
        string MonthsText(int value) => value.ToString(CultureInfo.InvariantCulture) + (Math.Abs(value) == 1 ? " month" : " months");
        if (Days == 0) return MonthsText(Months);
        if (Months == 0) return Days.ToString(CultureInfo.InvariantCulture) + " day";
        return "(" + MonthsText(Months) + (Days < 0 ? " - " : " + ") + Math.Abs(Days).ToString(CultureInfo.InvariantCulture) + " day)";
    }
}

/// <summary>Typed sheet result. Dates and calendar periods cannot silently become numeric magnitudes.</summary>
public readonly record struct SheetValue
{
    private readonly NumericValue number;
    private readonly DateOnly date;
    private readonly CalendarPeriod period;
    private readonly ClockTime time;
    private readonly LocalTimestamp timestamp;
    private readonly ZonedMoment moment;
    private readonly WorkdayPeriod? workdays;
    private readonly HolidaySet? holidays;
    private readonly MoneyValue? money;
    private readonly SheetList? list;
    private readonly EarningsValue? earnings;
    private readonly SheetMatrix? matrix;
    private readonly ResistorValue? resistor;
    private readonly EngineeringValue? engineering;
    private readonly IntegerValue? integer;
    private readonly NetworkValue? network;
    private readonly ColourValue? colour;
    public ColourValue Colour => Kind == SheetValueKind.Colour ? colour! : throw new ArithmeticException("Expected colour");
    private readonly PermissionValue? permission;
    public PermissionValue Permission => Kind == SheetValueKind.Permission ? permission! : throw new ArithmeticException("Expected permission");
    private readonly AspectValue? aspect;
    public AspectValue Aspect => Kind == SheetValueKind.Aspect ? aspect! : throw new ArithmeticException("Expected aspect");
    private readonly UnicodeValue? unicode;
    public UnicodeValue Unicode => Kind == SheetValueKind.Unicode ? unicode! : throw new ArithmeticException("Expected unicode");
    private readonly UsageCountValue? usageCount;
    public UsageCountValue UsageCount => Kind == SheetValueKind.UsageCount ? usageCount! : throw new ArithmeticException("Expected UsageCount");
    private readonly UsagePriceValue? usagePrice;
    public UsagePriceValue UsagePrice => Kind == SheetValueKind.UsagePrice ? usagePrice! : throw new ArithmeticException("Expected UsagePrice");
    private readonly UptimeBudgetValue? uptimeBudget;
    public UptimeBudgetValue UptimeBudget => Kind == SheetValueKind.UptimeBudget ? uptimeBudget! : throw new ArithmeticException("Expected UptimeBudget");
    private readonly TextValue? text;
    public TextValue Text => Kind == SheetValueKind.Text ? text! : throw new ArithmeticException("Expected text");
    private readonly ComplexValue? complex;
    public ComplexValue Complex => Kind == SheetValueKind.Complex ? complex! : throw new ArithmeticException("Expected a complex value");
    private readonly PrimeValue? prime;
    public PrimeValue Prime => Kind == SheetValueKind.Prime ? prime! : throw new ArithmeticException("Expected a primality or factorization result");
    private readonly EquationValue? equation;
    private readonly PracticalValue? practical;
    public PracticalValue Practical => Kind == SheetValueKind.Practical ? practical! : throw new ArithmeticException("Expected a practical helper result");
    public EquationValue Equation => Kind == SheetValueKind.Equation ? equation! : throw new ArithmeticException("Expected a solve result");
    private readonly PlotValue? plot;
    public PlotValue Plot => Kind == SheetValueKind.Plot ? plot! : throw new ArithmeticException("Expected a plot");
    private readonly ChartValue? chart;
    public ChartValue Chart => Kind == SheetValueKind.Chart ? chart! : throw new ArithmeticException("Expected a chart");
    private readonly TableValue? table;
    public TableValue Table => Kind == SheetValueKind.Table ? table! : throw new ArithmeticException("Expected a table");
    public NetworkValue Network => Kind == SheetValueKind.Network ? network! : throw new ArithmeticException("Expected a network value");
    public IntegerValue Integer => Kind == SheetValueKind.Integer ? integer! : throw new ArithmeticException("Expected an integer");
    public SheetValueKind Kind { get; }
    public NumericValue Number => Kind == SheetValueKind.Number ? number : throw new ArithmeticException("Expected a numeric value");
    public DateOnly Date => Kind == SheetValueKind.Date ? date : throw new ArithmeticException("Expected a date");
    public CalendarPeriod Period => Kind == SheetValueKind.CalendarPeriod ? period : throw new ArithmeticException("Expected a calendar period");
    public ClockTime Time => Kind == SheetValueKind.Time ? time : throw new ArithmeticException("Expected a clock reading");
    public LocalTimestamp Timestamp => Kind == SheetValueKind.LocalTimestamp ? timestamp : throw new ArithmeticException("Expected a local timestamp");
    public ZonedMoment Moment => Kind == SheetValueKind.ZonedMoment ? moment : throw new ArithmeticException("Expected a zoned timestamp");
    public WorkdayPeriod Workdays => Kind == SheetValueKind.WorkdayPeriod ? workdays! : throw new ArithmeticException("Expected working days");
    public HolidaySet Holidays => Kind == SheetValueKind.HolidayList ? holidays! : throw new ArithmeticException("Expected a holiday date list");
    public MoneyValue Money => Kind == SheetValueKind.Money ? money! : throw new ArithmeticException("Expected a monetary value");
    public SheetList List => Kind == SheetValueKind.List ? list! : throw new ArithmeticException("Expected a numeric list");
    public EarningsValue Earnings => Kind == SheetValueKind.Earnings ? earnings! : throw new ArithmeticException("Expected an earnings rate");
    public SheetMatrix Matrix => Kind == SheetValueKind.Matrix ? matrix! : throw new ArithmeticException("Expected a matrix");
    public ResistorValue Resistor => Kind == SheetValueKind.Resistor ? resistor! : throw new ArithmeticException("Expected a resistor marking");
    public EngineeringValue Engineering => Kind == SheetValueKind.Engineering ? engineering! : throw new ArithmeticException("Expected engineering notation");
    public string CopyText => Kind == SheetValueKind.Plot ? plot!.CopyText : Kind == SheetValueKind.Chart ? chart!.CopyText : Kind == SheetValueKind.Table ? table!.CopyText : Kind == SheetValueKind.Practical ? practical!.CopyText : Kind == SheetValueKind.Complex ? complex!.CopyText : Kind == SheetValueKind.Prime ? prime!.CopyText : Kind == SheetValueKind.Number && number.UseConstantNotation ? (number with { UseConstantNotation = false }).Display : Kind == SheetValueKind.Equation ? equation!.CopyText : Kind == SheetValueKind.UptimeBudget ? uptimeBudget!.CopyText : Kind == SheetValueKind.UsagePrice ? usagePrice!.CopyText : Kind == SheetValueKind.UsageCount ? usageCount!.CopyText : Kind == SheetValueKind.Unicode ? unicode!.CopyText : Kind == SheetValueKind.Aspect ? aspect!.CopyText : Kind == SheetValueKind.Permission ? permission!.CopyText : Kind == SheetValueKind.Colour ? colour!.CopyText : Kind == SheetValueKind.Text ? text!.CopyText : Kind == SheetValueKind.Network ? network!.CopyText : Kind == SheetValueKind.Integer ? integer!.CopyText : Kind == SheetValueKind.List ? list!.CopyText : Kind == SheetValueKind.Matrix ? matrix!.CopyText : Kind == SheetValueKind.Resistor ? resistor!.CopyText : Kind == SheetValueKind.Engineering ? engineering!.CopyText : Display;
    public Rational Scalar => Number.Scalar;
    public ExactNumber Exact => Number.Exact;
    public UnitExpression? Unit => Number.Unit;
    public string QuantityKind => Number.QuantityKind;
    public bool IsPercentage => Kind == SheetValueKind.Number && number.IsPercentage;
    public bool IsRational => Kind == SheetValueKind.Number && number.IsRational;
    public string Display => Kind switch { SheetValueKind.Plot => plot!.Display, SheetValueKind.Chart => chart!.Display, SheetValueKind.Table => table!.Display, SheetValueKind.Practical => practical!.Display, SheetValueKind.Complex => complex!.Display, SheetValueKind.Prime => prime!.Display, SheetValueKind.Equation => equation!.Display, SheetValueKind.UptimeBudget => uptimeBudget!.Display, SheetValueKind.UsagePrice => usagePrice!.Display, SheetValueKind.UsageCount => usageCount!.Display, SheetValueKind.Unicode => unicode!.Display, SheetValueKind.Aspect => aspect!.Display, SheetValueKind.Permission => permission!.Display, SheetValueKind.Colour => colour!.Display, SheetValueKind.Date => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), SheetValueKind.CalendarPeriod => period.ToString(), SheetValueKind.Time => time.ToString(), SheetValueKind.LocalTimestamp => timestamp.ToString(), SheetValueKind.ZonedMoment => moment.ToString(), SheetValueKind.WorkdayPeriod => workdays!.ToString(), SheetValueKind.HolidayList => holidays!.ToString(), SheetValueKind.Money => money!.Display, SheetValueKind.List => list!.Display, SheetValueKind.Earnings => earnings!.Display, SheetValueKind.Matrix => matrix!.Display, SheetValueKind.Resistor => resistor!.Display, SheetValueKind.Engineering => engineering!.Display, SheetValueKind.Integer => integer!.Display, SheetValueKind.Network => network!.Display, SheetValueKind.Text => text!.Display, _ => number.Display };
    public SheetValue(NumericValue value) { number = value; Kind = SheetValueKind.Number; }
    public SheetValue(Rational value) : this(new NumericValue(value)) { }
    public SheetValue(DateOnly value) { date = value; Kind = SheetValueKind.Date; }
    public SheetValue(CalendarPeriod value) { period = value.Checked(); Kind = SheetValueKind.CalendarPeriod; }
    public SheetValue(ClockTime value) { time = value.Checked(); Kind = SheetValueKind.Time; }
    public SheetValue(LocalTimestamp value) { timestamp = value; Kind = SheetValueKind.LocalTimestamp; }
    public SheetValue(ZonedMoment value) { moment = value.Checked(); Kind = SheetValueKind.ZonedMoment; }
    public SheetValue(WorkdayPeriod value) { workdays = value.Checked(); Kind = SheetValueKind.WorkdayPeriod; }
    public SheetValue(HolidaySet value) { holidays = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.HolidayList; }
    public SheetValue(MoneyValue value) { money = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Money; }
    public SheetValue(SheetList value) { list = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.List; }
    public SheetValue(EarningsValue value) { earnings = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Earnings; }
    public SheetValue(SheetMatrix value) { matrix = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Matrix; }
    public SheetValue(ResistorValue value) { resistor = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Resistor; }
    public SheetValue(ColourValue value) { colour = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Colour; }
    public SheetValue(PermissionValue value) { permission = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Permission; }
    public SheetValue(AspectValue value) { aspect = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Aspect; }
    public SheetValue(UnicodeValue value) { unicode = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Unicode; }
    public SheetValue(UsageCountValue value) { usageCount = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.UsageCount; }
    public SheetValue(UsagePriceValue value) { usagePrice = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.UsagePrice; }
    public SheetValue(UptimeBudgetValue value) { uptimeBudget = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.UptimeBudget; }
    public SheetValue(TextValue value) { text = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Text; }
    public SheetValue(NetworkValue value) { network = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Network; }
    public SheetValue(IntegerValue value) { integer = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Integer; }
    public SheetValue(EngineeringValue value) { engineering = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Engineering; }
    public SheetValue(ComplexValue value) { complex = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Complex; }
    public SheetValue(PrimeValue value) { prime = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Prime; }
    public SheetValue(PracticalValue value) { practical = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Practical; }
    public SheetValue(EquationValue value) { equation = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Equation; }
    public SheetValue(PlotValue value) { plot = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Plot; }
    public SheetValue(ChartValue value) { chart = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Chart; }
    public SheetValue(TableValue value) { table = value ?? throw new ArgumentNullException(nameof(value)); Kind = SheetValueKind.Table; }
    public static implicit operator SheetValue(NumericValue value) => new(value);
    public override string ToString() => Display;
}

/// <summary>A host-supplied snapshot, shared by every line and nested call in one evaluation.</summary>
public sealed record EvaluationContext(DateOnly? Today = null, DateTimeOffset? Now = null, NodaTime.IDateTimeZoneProvider? TimeZones = null, LocalZoneSnapshot? LocalZone = null,
    string? WorkdayRegion = null, HolidaySet? CustomHolidays = null, CurrencyRateBook? CurrencyRates = null)
{
    public StableUuidContext? Uuids { get; init; }
    internal int UuidLine { get; init; }
    internal string UuidPath { get; init; } = "";
    internal IReadOnlyList<string>? AggregateLabels { get; init; }
    public DateOnly? CurrencyDate { get; init; }
    public string? PayrollRegion { get; init; }
    /// <summary>Currency a sheet shows plain monetary results in. Display-only: values, references and copies keep their own currency.</summary>
    public string? DisplayCurrency { get; init; }
    internal DateOnly RequireToday() => Today ?? throw new ArithmeticException("Current date unavailable; supply an evaluation context");
    internal NodaTime.Instant RequireNow() => NodaTime.Instant.FromDateTimeOffset(Now ?? throw new ArithmeticException("Current instant unavailable; supply an evaluation context"));
    internal NodaTime.IDateTimeZoneProvider Zones => TimeZones ?? NodaTime.DateTimeZoneProviders.Tzdb;
    internal LocalZoneSnapshot RequireLocalZone(ContextReads reads)
    {
        reads.Dependencies |= ContextDependency.LocalZone;
        return LocalZone ?? throw new ArithmeticException("Local time-zone rules unavailable; supply an evaluation context");
    }
}
