namespace Calc.Core;

internal sealed partial class HelperArithmetic
{
    private static readonly UnitExpression Litres = UnitExpression.Single(UnitCatalog.ById("L"));
    private static readonly Rational DefaultCoverage = new(10000, 1), DefaultWaste = new(1, 10), DefaultDensity = new(2300, 1), DefaultBag = new(25, 1);
    internal const string PaintBasis = "Paint (litres) = area * coats / coverage; default coverage 10 m2 per litre per coat and one coat; override with 'N coats' and 'at 12 m2/l'; no allowance for openings, absorbent surfaces or tin sizes; two-decimal display, exact value kept";
    internal const string TileBasis = "Tiles = area * (1 + waste); default waste 10%; override with '15% waste'; the area keeps its unit; whole-tile counts, layout and cuts are not modelled; two-decimal display, exact value kept";
    internal const string ConcreteBasis = "Concrete bags = volume * density / bag mass, rounded up to whole bags; defaults 2300 kg/m3 for ready-mixed concrete and 25 kg bags; override with '40 kg bags' and 'at 2400 kg/m3'; no waste, formwork or mix-yield allowance";
    private static Rational Coats(SheetValue value)
    {
        var coats = Plain(value, "Coats");
        if (coats.Denominator != 1 || coats.Numerator.Sign <= 0 || coats.Above(new Rational(20, 1))) throw new ArithmeticException("Coats must be a whole number from 1 to 20");
        return coats;
    }
    internal Outcome Paint(SheetValue[] inputs, string[] words)
    {
        var area = Quantity(inputs[0], Area, "Area", "area"); var next = 1;
        var coats = words.Contains("coats") ? Coats(inputs[next++]) : new Rational(1, 1);
        var coverage = words.Contains("rate") ? Quantity(inputs[next], PerLength, "Coverage", "area-per-volume (m2/l)") : DefaultCoverage;
        var volume = new NumericValue(new ExactNumber(area * coats / coverage), Litres) { DisplayDecimalPlaces = 2, IsApproximate = Approximate(inputs) };
        return new(Result(volume), "paint", PaintBasis + "; used " + coats + (coats == new Rational(1, 1) ? " coat" : " coats") + " at " + coverage / new Rational(1000, 1) + " m2/l" + (words.Contains("rate") ? "" : " (default)"));
    }
    internal Outcome Tiles(SheetValue[] inputs)
    {
        var number = NumberOf(inputs[0], "Area"); var area = Quantity(inputs[0], Area, "Area", "area");
        var waste = inputs.Length > 1 ? PercentWaste(inputs[1]) : DefaultWaste;
        var tiles = number with { Exact = new ExactNumber(area * (new Rational(1, 1) + waste)), DisplayDecimalPlaces = 2, IsApproximate = Approximate(inputs) };
        return new(Result(tiles), "tiles", TileBasis + "; used " + waste * new Rational(100, 1) + "% waste" + (inputs.Length > 1 ? "" : " (default)"));
    }
    private static Rational PercentWaste(SheetValue value)
    {
        var number = NumberOf(value, "Waste");
        if (!number.IsPercentage || number.Unit is not null || !number.IsRational) throw new ArithmeticException("Waste must be a percentage such as 15%");
        var waste = number.Exact.Rational;
        if (waste.Numerator.Sign < 0 || waste.Above(new Rational(1, 1))) throw new ArithmeticException("Waste must be between 0% and 100%");
        return waste;
    }
    internal Outcome Concrete(SheetValue[] inputs, string[] words)
    {
        var volume = Quantity(inputs[0], Volume, "Volume", "volume"); var next = 1;
        var bag = words.Contains("bag") ? Quantity(inputs[next++], Mass, "Bag mass", "mass") : DefaultBag;
        var density = words.Contains("density") ? Quantity(inputs[next], Density, "Density", "density (kg/m3)") : DefaultDensity;
        var bags = CeilingOfPositive(volume * density / bag);
        var count = new NumericValue(new Rational(bags, 1)) { IsApproximate = Approximate(inputs) };
        return new(Result(count), "concrete", ConcreteBasis + "; used " + density + " kg/m3 and " + bag + " kg bags" + (words.Length == 0 ? " (defaults)" : "") + "; " + volume * density + " kg of concrete");
    }
}
