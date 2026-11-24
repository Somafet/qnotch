import Foundation

extension Rational {
    /// C# RationalOrder.Above: strictly greater, by the sign of the difference.
    func above(_ other: Rational) throws -> Bool { try (self - other).sign > 0 }
}

/// Bounded practical estimators: cooking, body metrics, running, home materials and fuel. Every model, constant and default is disclosed in the step assumption;
/// results are formula estimates (never medical or professional advice) and keep exact values unless a floating-point model is involved.
/// The C# partial class is split the same way here: CookingArithmetic, HealthArithmetic, FuelArithmetic, RunningArithmetic and HomeEstimateArithmetic extend it.
final class HelperArithmetic {
    typealias Outcome = (value: SheetValue, operation: String, assumption: String)
    static let mass = Dimension(0, 1, 0, 0, 0, 0, 0, 0), length = Dimension(1, 0, 0, 0, 0, 0, 0, 0), time = Dimension(0, 0, 1, 0, 0, 0, 0, 0)
    static let area = Dimension(2, 0, 0, 0, 0, 0, 0, 0), volume = Dimension(3, 0, 0, 0, 0, 0, 0, 0), timePerLength = Dimension(-1, 0, 1, 0, 0, 0, 0, 0)
    static let perLength = Dimension(-1, 0, 0, 0, 0, 0, 0, 0), density = Dimension(-3, 1, 0, 0, 0, 0, 0, 0)
    static func isFunction(_ name: String) -> Bool { name.equalsIgnoreCase("bmi") }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 2 { throw CalcError.format(name + " expects a mass and a height") } }

    let math: ExactArithmetic, budget: ExecutionBudget, context: EvaluationContext, reads: ContextReads, token: CancellationToken
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ context: EvaluationContext, _ reads: ContextReads, _ token: CancellationToken) {
        self.math = math; self.budget = budget; self.context = context; self.reads = reads; self.token = token
    }
    func function(_ name: String, _ args: [SheetValue]) throws -> Outcome { try HelperArithmetic.validateArity(name, args.count); return try bmi(args[0], args[1]) }
    func evaluate(_ node: HelperExpression, _ inputs: [SheetValue]) throws -> Outcome {
        try budget.step(token)
        switch node.kind {
        case .bmr: return try bmr(inputs, node.words[0])
        case .tdee: return try tdee(inputs, node.words[0], node.words[1])
        case .heartZones: return try heartZones(inputs[0], node.words[0])
        case .pace: return try pace(inputs[0], inputs[1])
        case .runTime: return try runTime(inputs[0], inputs[1])
        case .race: return try race(inputs[0], inputs[1], inputs[2])
        case .paint: return try paint(inputs, node.words)
        case .tiles: return try tiles(inputs)
        case .concrete: return try concrete(inputs, node.words)
        case .fuelTrip: return try fuelTrip(inputs)
        case .timeDifference: return try timeDifference(inputs, node.words[0], node.words[1])
        case .scale: return try scale(inputs[0], inputs[1], inputs[2])
        case .ingredient: return try ingredient(inputs[0], node.words[0], node.unit!)
        case .count: return (inputs[0], node.words[0], "Dimensionless count label: the number is unchanged")
        }
    }
    static func numberOf(_ value: SheetValue, _ role: String) throws -> NumericValue {
        guard case .number(let number) = value else { throw CalcError.arithmetic(role + " must be a number or quantity") }
        return number
    }
    static func approximate(_ values: [SheetValue]) -> Bool { values.contains { if case .number(let n) = $0 { return n.isApproximate }; return false } }
    static func approximate(_ values: SheetValue...) -> Bool { approximate(values) }
    /// The canonical (SI) rational magnitude of a quantity of the given dimension, strictly positive unless `allowZero`.
    static func quantity(_ value: SheetValue, _ dimension: Dimension, _ role: String, _ hint: String, allowZero: Bool = false) throws -> Rational {
        let number = try numberOf(value, role)
        guard !number.isPercentage, let unit = number.unit, unit.dimension == dimension, !unit.isTemperaturePoint else { throw CalcError.arithmetic(role + " must be a " + hint + " quantity") }
        if !number.isRational { throw CalcError.arithmetic(role + " must be an exact rational quantity") }
        let magnitude = try number.exact.rational
        if magnitude.sign < 0 || magnitude.isZero && !allowZero { throw CalcError.arithmetic(role + " must be positive") }
        return magnitude
    }
    static func plain(_ value: SheetValue, _ role: String) throws -> Rational {
        let number = try numberOf(value, role)
        if number.isPercentage || number.unit != nil || !number.isRational { throw CalcError.arithmetic(role + " must be a plain exact number") }
        return try number.exact.rational
    }
    static func result(_ value: NumericValue) -> SheetValue { .number(value) }
    static func seconds(_ seconds: Rational, _ approximate: Bool = false) throws -> NumericValue {
        NumericValue(ExactNumber(seconds), unit: try .single(UnitCatalog.byId("s"))).with { $0.isApproximate = approximate }
    }
    static func ceilingOfPositive(_ value: Rational) -> BigInt { (value.numerator + value.denominator - 1) / value.denominator }
}
