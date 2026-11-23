using System.Numerics;

namespace Calc.Core;

internal sealed partial class HelperArithmetic
{
    internal const string BmiBasis = "BMI = mass (kg) / height (m)^2 (Quetelet index), shown to one decimal with the exact value kept; no category, target or health advice; bounds 0 < mass <= 1000 kg, 0 < height <= 3 m";
    internal const string BmrBasis = "Basal metabolic rate, Mifflin-St Jeor (1990): 10 * mass kg + 6.25 * height cm - 5 * age years + 5 (male) or - 161 (female); kilocalories per day at rest, shown to whole kcal with the exact value kept; a population estimate for adults, not medical advice; bounds 0 < mass <= 1000 kg, 0 < height <= 3 m, 0 < age <= 150 years";
    internal const string TdeeBasis = "Total daily energy expenditure = BMR (Mifflin-St Jeor) * activity factor; kilocalories per day; factors: sedentary 1.2, light 1.375, moderate 1.55, active 1.725, very active 1.9; an estimate, not medical advice";
    internal const string ZoneBasis = "Maximum heart rate = 220 - age (a common population estimate; individual maxima differ widely) or the supplied maximum; zones are 50-60%, 60-70%, 70-80%, 80-90% and 90-100% of that maximum, each boundary rounded to whole bpm (halves up) and shared by neighbouring zones; not medical advice";
    private static readonly Dictionary<string, Rational> ActivityFactors = new()
    {
        ["sedentary"] = new(12, 10), ["light"] = new(1375, 1000), ["moderate"] = new(155, 100), ["active"] = new(1725, 1000), ["very active"] = new(19, 10)
    };
    private static NumericValue Kilocalories(Rational kcal) => new(new ExactNumber(kcal * UnitCatalog.ById("kcal").Factor), UnitExpression.Single(UnitCatalog.ById("kcal"))) { DisplayDecimalPlaces = 0 };
    private static Rational Age(SheetValue value)
    {
        var age = Plain(value, "Age");
        if (age.Numerator.Sign <= 0 || age.Above(new Rational(150, 1))) throw new ArithmeticException("Age must be above 0 and at most 150 years");
        return age;
    }
    private (Rational Mass, Rational Height) Body(SheetValue mass, SheetValue height)
    {
        var kilograms = Quantity(mass, Mass, "Mass", "mass"); var metres = Quantity(height, Length, "Height", "length");
        if (kilograms.Above(new Rational(1000, 1))) throw new ArithmeticException("Mass must be at most 1000 kg");
        if (metres.Above(new Rational(3, 1))) throw new ArithmeticException("Height must be at most 3 m");
        return (kilograms, metres);
    }
    internal Outcome Bmi(SheetValue mass, SheetValue height)
    {
        var (kilograms, metres) = Body(mass, height);
        var value = new NumericValue(new ExactNumber(kilograms / (metres * metres))) { DisplayDecimalPlaces = 1, IsApproximate = Approximate(mass, height) };
        return new(Result(value), "bmi", BmiBasis);
    }
    private Rational BmrValue(SheetValue[] inputs, string sex)
    {
        var (kilograms, metres) = Body(inputs[0], inputs[1]); var age = Age(inputs[2]);
        var bmr = new Rational(10, 1) * kilograms + new Rational(625, 100) * metres * new Rational(100, 1) - new Rational(5, 1) * age + new Rational(sex == "male" ? 5 : -161, 1);
        if (bmr.Numerator.Sign <= 0) throw new ArithmeticException("The Mifflin-St Jeor estimate is not positive for these inputs");
        return bmr;
    }
    internal Outcome Bmr(SheetValue[] inputs, string sex) => new(Result(Kilocalories(BmrValue(inputs, sex)) with { IsApproximate = Approximate(inputs) }), "bmr", BmrBasis + "; " + sex);
    internal Outcome Tdee(SheetValue[] inputs, string sex, string level)
    {
        var factor = ActivityFactors[level];
        return new(Result(Kilocalories(BmrValue(inputs, sex) * factor) with { IsApproximate = Approximate(inputs) }), "tdee", TdeeBasis + "; " + sex + ", " + level + " (" + factor + ")");
    }
    internal Outcome HeartZones(SheetValue value, string mode)
    {
        var maximum = mode == "age" ? new Rational(220, 1) - Age(value) : Plain(value, "Maximum heart rate");
        if (maximum.Numerator.Sign <= 0 || maximum.Above(new Rational(300, 1))) throw new ArithmeticException("Maximum heart rate must be above 0 and at most 300 bpm");
        var edges = Enumerable.Range(5, 6).Select(tenths => (int)PracticalValue.Round(maximum * new Rational(tenths, 10))).ToArray();
        var zones = Enumerable.Range(0, 5).Select(i => new HeartRateZone(i + 1, edges[i], edges[i + 1])).ToArray();
        return new(new SheetValue(PracticalValue.ForZones(zones)), "heart-rate zones", ZoneBasis + "; maximum " + maximum + " bpm");
    }
}
