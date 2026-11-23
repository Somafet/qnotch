namespace Calc.Core;

internal sealed partial class HelperArithmetic
{
    private static readonly Rational CupCubicMetres = UnitCatalog.ById("cup").Factor;
    internal Outcome Scale(SheetValue amount, SheetValue from, SheetValue to)
    {
        var source = NumberOf(amount, "Amount"); var servings = Plain(from, "Original servings"); var target = Plain(to, "New servings");
        if (servings.Numerator.Sign <= 0 || target.Numerator.Sign <= 0) throw new ArithmeticException("Servings must be positive");
        var scaled = source with { Exact = math.Scale(source.Exact, target / servings) };
        return new(Result(scaled), "scale servings", "Amount * new servings / original servings (" + target + "/" + servings + "); amounts are assumed to scale linearly, which cooking times, leavening and pan sizes may not");
    }
    internal Outcome Ingredient(SheetValue amount, string id, UnitExpression target)
    {
        var ingredient = IngredientCatalog.Ingredients.First(item => item.Id == id);
        var source = NumberOf(amount, "Amount");
        if (source.Unit is null || source.IsPercentage || source.Unit.IsTemperaturePoint || source.Unit.Dimension != Volume && source.Unit.Dimension != Mass) throw new ArithmeticException("Ingredient conversion needs a volume or a mass");
        if (target.Dimension != Volume && target.Dimension != Mass) throw new ArithmeticException("Ingredient conversion targets a volume or a mass unit");
        if (!source.IsRational || source.Exact.Rational.Numerator.Sign < 0) throw new ArithmeticException("Ingredient amount must be a nonnegative exact quantity");
        if (source.Unit.Dimension == target.Dimension)
            return new(Result(new QuantityArithmetic(math).Convert(source, target)), "convert unit", "Same dimension: " + ingredient.Id + " density not used");
        var magnitude = source.Exact.Rational; var kilogramsPerCup = ingredient.GramsPerCup / new Rational(1000, 1);
        var converted = source.Unit.Dimension == Volume ? magnitude / CupCubicMetres * kilogramsPerCup : magnitude / kilogramsPerCup * CupCubicMetres;
        var result = new NumericValue(new ExactNumber(converted), target) { IsApproximate = true, DisplayDecimalPlaces = 2 };
        return new(Result(result), "ingredient conversion", "Estimate: " + ingredient.Id + " = " + ingredient.GramsPerCup + " g per US cup (1 cup = 236.5882365 mL, exact); source " + ingredient.Source +
            (ingredient.Note.Length > 0 ? "; " + ingredient.Note : "") + "; real density varies with brand, moisture, sifting and packing");
    }
}
