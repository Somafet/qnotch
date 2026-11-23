namespace Calc.Core;

internal sealed partial class HelperArithmetic
{
    internal const string RiegelBasis = "Riegel's endurance model: T2 = T1 * (D2 / D1)^1.06 with the exponent fixed at 1.06; computed in double precision and kept to 12 significant digits (approximate); shown in whole seconds; a prediction for comparable efforts, with the distance ratio limited to 1/100..100";
    private static readonly UnitExpression SecondsPerKilometre = UnitExpression.Single(UnitCatalog.ById("s")).Combine(UnitExpression.Single(UnitCatalog.ById("km")), -1);
    private static SheetValue Clock(Rational seconds, bool approximate = false) => new(PracticalValue.ForClock(Seconds(seconds, approximate), seconds));
    private static (Rational Metres, Rational Seconds) Effort(SheetValue distance, SheetValue time) => (Quantity(distance, Length, "Distance", "length"), Quantity(time, Time, "Time", "time"));
    internal Outcome Pace(SheetValue distance, SheetValue time)
    {
        var (metres, seconds) = Effort(distance, time); var perMetre = seconds / metres;
        var pace = new NumericValue(new ExactNumber(perMetre), SecondsPerKilometre) { IsApproximate = Approximate(distance, time) };
        return new(new SheetValue(PracticalValue.ForPace(pace, perMetre)), "pace", "Pace = elapsed time / distance, shown as m:ss per kilometre and per mile (1 mi = 1609.344 m); whole seconds, halves up; exact value kept");
    }
    internal Outcome RunTime(SheetValue distance, SheetValue pace)
    {
        var metres = Quantity(distance, Length, "Distance", "length"); var perMetre = Quantity(pace, TimePerLength, "Pace", "time-per-distance");
        return new(Clock(metres * perMetre, Approximate(distance, pace)), "time at pace", "Time = distance * pace; shown as m:ss below one hour and h:mm:ss from one hour, whole seconds, halves up; exact value kept");
    }
    internal Outcome Race(SheetValue distance, SheetValue time, SheetValue target)
    {
        var (metres, seconds) = Effort(distance, time); var targetMetres = Quantity(target, Length, "Target distance", "length");
        var ratio = targetMetres / metres;
        if (ratio.Above(new Rational(100, 1)) || new Rational(1, 100).Above(ratio)) throw new ArithmeticException("Riegel predictions are limited to a distance change between 1/100 and 100 times");
        if (ratio == new Rational(1, 1)) return new(Clock(seconds, Approximate(distance, time)), "race prediction", RiegelBasis + "; target equals the given distance, time unchanged");
        var predicted = FormulaNumbers.FromDouble(FormulaNumbers.ToDouble(seconds) * Math.Pow(FormulaNumbers.ToDouble(ratio), 1.06), 12);
        return new(Clock(predicted, true), "race prediction", RiegelBasis);
    }
}
