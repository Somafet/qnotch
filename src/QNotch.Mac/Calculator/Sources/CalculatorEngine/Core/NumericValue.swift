import Foundation

/// Exact dimensionless number, percentage ratio or quantity. Formatting is not authoritative data.
struct NumericValue: Hashable {
    var exact: ExactNumber = .zero
    var unit: UnitExpression?
    /// "" when none (C# stores null and reads "").
    var quantityKind = ""
    var isPercentage = false
    var useCompoundDuration = false
    var useDaysInDuration = false
    var isApproximate = false
    /// Compact presentation of a named constant: comma groups or scientific form. Copy keeps the complete digits.
    var useConstantNotation = false
    var displayDecimalPlaces: Int?

    /// `default(NumericValue)`: zero.
    init() {}
    init(_ scalar: Rational, isPercentage: Bool = false) { exact = ExactNumber(scalar); self.isPercentage = isPercentage }
    init(_ exact: ExactNumber, isPercentage: Bool = false) { self.exact = exact; self.isPercentage = isPercentage }
    init(_ exact: ExactNumber, unit: UnitExpression) { self.exact = exact; self.unit = unit; quantityKind = unit.kind }

    /// The dimensionless rational value; throws for quantities and radicals.
    var scalar: Rational { get throws { if unit != nil { throw CalcError.arithmetic("Expected a dimensionless value") }; return try exact.rational } }
    var isRational: Bool { exact.isRational }
    /// A quantity of time, which a host may present as days, hours and minutes.
    var isDuration: Bool { unit?.dimension == TimeArithmetic.timeDimension }
    /// C# `value with { … }`.
    func with(_ change: (inout NumericValue) -> Void) -> NumericValue { var copy = self; change(&copy); return copy }

    var display: String {
        get throws {
            if useCompoundDuration && unit?.dimension == TimeArithmetic.timeDimension { return (isApproximate ? "≈ " : "") + (try TimeSyntax.duration(exact, includeDays: useDaysInDuration)) }
            let math = ExactArithmetic(ExecutionBudget(), .none)
            var value = unit != nil ? try QuantityArithmetic(math).displayMagnitude(self) : isPercentage ? try math.scale(exact, Rational(100)) : exact
            if let places = displayDecimalPlaces {
                if places < 0 || places > 256 { throw CalcError.arithmetic("Invalid display precision") }
                value = try ExactRounding.apply(.decimalPlaces, NumericValue(value), NumericValue(Rational(places)), .none, math).exact
            }
            var rounded = false
            let number = useConstantNotation ? try ConstantCatalog.notation(value, math, &rounded) : try value.text()
            let grouped = !useConstantNotation && (isPercentage || unit != nil) && (!value.isRational || number.contains("/"))
            let text = (isApproximate || rounded ? "≈ " : "") + (grouped ? "(" + number + ")" : number) + (isPercentage ? "%" : unit != nil ? " " + unit!.symbol : "")
            if text.netLength > 2048 { throw CalcError.arithmetic("Output limit exceeded") }
            return text
        }
    }
}
