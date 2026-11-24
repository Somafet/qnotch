import Foundation

extension HelperArithmetic {
    private static var litres: UnitExpression { get throws { try .single(UnitCatalog.byId("L")) } }
    private static let defaultCoverage = Rational(10000), defaultWaste = try! Rational(1, 10), defaultDensity = Rational(2300), defaultBag = Rational(25)
    static let paintBasis = "Paint (litres) = area * coats / coverage; default coverage 10 m2 per litre per coat and one coat; override with 'N coats' and 'at 12 m2/l'; no allowance for openings, absorbent surfaces or tin sizes; two-decimal display, exact value kept"
    static let tileBasis = "Tiles = area * (1 + waste); default waste 10%; override with '15% waste'; the area keeps its unit; whole-tile counts, layout and cuts are not modelled; two-decimal display, exact value kept"
    static let concreteBasis = "Concrete bags = volume * density / bag mass, rounded up to whole bags; defaults 2300 kg/m3 for ready-mixed concrete and 25 kg bags; override with '40 kg bags' and 'at 2400 kg/m3'; no waste, formwork or mix-yield allowance"
    private static func coats(_ value: SheetValue) throws -> Rational {
        let coats = try plain(value, "Coats")
        if try !coats.denominator.isOne || coats.sign <= 0 || coats.above(Rational(20)) { throw CalcError.arithmetic("Coats must be a whole number from 1 to 20") }
        return coats
    }
    func paint(_ inputs: [SheetValue], _ words: [String]) throws -> Outcome {
        let area = try HelperArithmetic.quantity(inputs[0], HelperArithmetic.area, "Area", "area"); var next = 1
        let coats: Rational
        if words.contains("coats") { coats = try HelperArithmetic.coats(inputs[next]); next += 1 } else { coats = .one }
        let rate = words.contains("rate")
        let coverage = rate ? try HelperArithmetic.quantity(inputs[next], HelperArithmetic.perLength, "Coverage", "area-per-volume (m2/l)") : HelperArithmetic.defaultCoverage
        let volume = NumericValue(ExactNumber(try area * coats / coverage), unit: try HelperArithmetic.litres).with { $0.displayDecimalPlaces = 2; $0.isApproximate = HelperArithmetic.approximate(inputs) }
        return (HelperArithmetic.result(volume), "paint", HelperArithmetic.paintBasis + "; used " + coats.description + (coats == .one ? " coat" : " coats") + " at " +
                (try coverage / Rational(1000)).description + " m2/l" + (rate ? "" : " (default)"))
    }
    func tiles(_ inputs: [SheetValue]) throws -> Outcome {
        let number = try HelperArithmetic.numberOf(inputs[0], "Area"); let area = try HelperArithmetic.quantity(inputs[0], HelperArithmetic.area, "Area", "area")
        let waste = inputs.count > 1 ? try HelperArithmetic.percentWaste(inputs[1]) : HelperArithmetic.defaultWaste
        let exact = ExactNumber(try area * (Rational.one + waste))
        let tiles = number.with { $0.exact = exact; $0.displayDecimalPlaces = 2; $0.isApproximate = HelperArithmetic.approximate(inputs) }
        return (HelperArithmetic.result(tiles), "tiles", HelperArithmetic.tileBasis + "; used " + (try waste * Rational(100)).description + "% waste" + (inputs.count > 1 ? "" : " (default)"))
    }
    private static func percentWaste(_ value: SheetValue) throws -> Rational {
        let number = try numberOf(value, "Waste")
        if !number.isPercentage || number.unit != nil || !number.isRational { throw CalcError.arithmetic("Waste must be a percentage such as 15%") }
        let waste = try number.exact.rational
        if try waste.sign < 0 || waste.above(.one) { throw CalcError.arithmetic("Waste must be between 0% and 100%") }
        return waste
    }
    func concrete(_ inputs: [SheetValue], _ words: [String]) throws -> Outcome {
        let volume = try HelperArithmetic.quantity(inputs[0], HelperArithmetic.volume, "Volume", "volume"); var next = 1
        let bag: Rational
        if words.contains("bag") { bag = try HelperArithmetic.quantity(inputs[next], HelperArithmetic.mass, "Bag mass", "mass"); next += 1 } else { bag = HelperArithmetic.defaultBag }
        let density = words.contains("density") ? try HelperArithmetic.quantity(inputs[next], HelperArithmetic.density, "Density", "density (kg/m3)") : HelperArithmetic.defaultDensity
        let bags = HelperArithmetic.ceilingOfPositive(try volume * density / bag)
        let count = NumericValue(try Rational(bags)).with { $0.isApproximate = HelperArithmetic.approximate(inputs) }
        return (HelperArithmetic.result(count), "concrete", HelperArithmetic.concreteBasis + "; used " + density.description + " kg/m3 and " + bag.description + " kg bags" +
                (words.isEmpty ? " (defaults)" : "") + "; " + (try volume * density).description + " kg of concrete")
    }
}
