import Foundation

extension HelperArithmetic {
    private static let cupCubicMetres = UnitCatalog.byId("cup").factor
    func scale(_ amount: SheetValue, _ from: SheetValue, _ to: SheetValue) throws -> Outcome {
        let source = try HelperArithmetic.numberOf(amount, "Amount"), servings = try HelperArithmetic.plain(from, "Original servings"), target = try HelperArithmetic.plain(to, "New servings")
        if servings.sign <= 0 || target.sign <= 0 { throw CalcError.arithmetic("Servings must be positive") }
        let scaledExact = try math.scale(source.exact, target / servings)
        return (HelperArithmetic.result(source.with { $0.exact = scaledExact }), "scale servings",
                "Amount * new servings / original servings (" + target.description + "/" + servings.description + "); amounts are assumed to scale linearly, which cooking times, leavening and pan sizes may not")
    }
    func ingredient(_ amount: SheetValue, _ id: String, _ target: UnitExpression) throws -> Outcome {
        let ingredient = IngredientCatalog.ingredients.first { $0.id.ordinalEquals(id) }!
        let source = try HelperArithmetic.numberOf(amount, "Amount")
        guard let unit = source.unit, !source.isPercentage, !unit.isTemperaturePoint, unit.dimension == HelperArithmetic.volume || unit.dimension == HelperArithmetic.mass else {
            throw CalcError.arithmetic("Ingredient conversion needs a volume or a mass")
        }
        if target.dimension != HelperArithmetic.volume && target.dimension != HelperArithmetic.mass { throw CalcError.arithmetic("Ingredient conversion targets a volume or a mass unit") }
        if try !source.isRational || source.exact.rational.sign < 0 { throw CalcError.arithmetic("Ingredient amount must be a nonnegative exact quantity") }
        if unit.dimension == target.dimension {
            return (HelperArithmetic.result(try QuantityArithmetic(math).convert(source, target)), "convert unit", "Same dimension: " + ingredient.id + " density not used")
        }
        let magnitude = try source.exact.rational, kilogramsPerCup = try ingredient.gramsPerCup / Rational(1000)
        let converted = unit.dimension == HelperArithmetic.volume ? try magnitude / HelperArithmetic.cupCubicMetres * kilogramsPerCup : try magnitude / kilogramsPerCup * HelperArithmetic.cupCubicMetres
        let result = NumericValue(ExactNumber(converted), unit: target).with { $0.isApproximate = true; $0.displayDecimalPlaces = 2 }
        return (HelperArithmetic.result(result), "ingredient conversion",
                "Estimate: " + ingredient.id + " = " + ingredient.gramsPerCup.description + " g per US cup (1 cup = 236.5882365 mL, exact); source " + ingredient.source +
                    (ingredient.note.isEmpty ? "" : "; " + ingredient.note) + "; real density varies with brand, moisture, sifting and packing")
    }
}
