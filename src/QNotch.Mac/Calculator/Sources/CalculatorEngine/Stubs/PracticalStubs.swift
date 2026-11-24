// Stub for the practical area: cooking, chemistry, electrical, health, fuel, running, home estimates,
// engineering notation, grades and helper sentences.

final class ChemistryExpression: Expression {
    let formula: String, amount: Expression?, target: UnitExpression?
    init(_ formula: String, amount: Expression? = nil, target: UnitExpression? = nil) { self.formula = formula; self.amount = amount; self.target = target }
    var children: [Expression] { amount.map { [$0] } ?? [] }
}
final class GradesExpression: Expression {
    let scores: [Expression], weights: [Expression]
    init(_ scores: [Expression], _ weights: [Expression]) { self.scores = scores; self.weights = weights }
    var children: [Expression] { scores + weights }
}
final class ResistorLiteralExpression: Expression { let bands: [String]; init(_ bands: [String]) { self.bands = bands } }
enum HelperKind { case bmr, tdee, heartZones, pace, runTime, race, paint, tiles, concrete, fuelTrip, timeDifference, scale, ingredient, count }
final class HelperExpression: Expression {
    let kind: HelperKind, operands: [Expression], words: [String], unit: UnitExpression?
    init(_ kind: HelperKind, _ operands: [Expression], _ words: [String], _ unit: UnitExpression? = nil) { self.kind = kind; self.operands = operands; self.words = words; self.unit = unit }
    var children: [Expression] { operands }
}
final class ChemistryEvidence { let formula = "", ruleId = "" }
final class ResistorValue: IdentityHashable {
    let nominal = NumericValue()
    var display: String { get throws { throw notPorted("resistor markings") } }
    var copyText: String { get throws { try display } }
}
final class EngineeringValue: IdentityHashable {
    let original = NumericValue()
    var display: String { get throws { throw notPorted("engineering notation") } }
    var copyText: String { get throws { try display } }
}
final class PracticalValue: IdentityHashable {
    let original: NumericValue? = nil
    var isApproximate: Bool { false }
    var display: String { get throws { throw notPorted("practical helpers") } }
    var copyText: String { get throws { try display } }
}
struct ResistorColor { let name: String }
enum ResistorColorCatalog { static func tryGet(_ text: String) -> ResistorColor? { nil } }
final class PracticalArithmetic {
    static let engineeringAssumption = "Engineering display: exponent multiple of three, six significant figures and available decimal SI units; original exact magnitude and approximation provenance retained; copied expression reconstructs the represented value"
    static func isFunction(_ name: String) -> Bool { ["engineering", "weightedmean", "grades", "molarmass", "moles", "massof"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let key = name.netLower
        if key == "engineering" { if count < 1 || count > 2 { throw CalcError.format("engineering expects a value and optional represented-approximation flag") } }
        else if count != (key == "molarmass" ? 1 : 2) { throw CalcError.format("\(name) has an invalid argument count") }
    }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func engineering(_ args: [SheetValue]) throws -> SheetValue { throw notPorted("engineering notation") }
    func grades(_ scores: [SheetValue], _ weights: [SheetValue]) throws -> SheetValue { throw notPorted("weighted grades") }
}
final class ChemistryArithmetic {
    static let assumption = "Nominal molar mass from CIAAW abridged 2024 weights; natural isotope variation and quoted atomic-weight uncertainties are not propagated; not an exact physical constant, isotope-specific mass or purity model"
    init(_ budget: ExecutionBudget, _ token: CancellationToken) {}
    func evaluate(_ expression: ChemistryExpression, _ amount: SheetValue?) throws -> (value: SheetValue, evidence: ChemistryEvidence) { throw notPorted("chemistry") }
}
final class ElectricalArithmetic {
    static let parallelAssumption = "Passive DC parallel resistance; reciprocal sum 1 / sum(1/R); zero is an ideal short; nonnegative finite inputs; no frequency/temperature/lead or tolerance interval model"
    static let resistanceDimension = Dimension(2, 1, -3, -2, 0, 0, 0, 0)
    static func isFunction(_ name: String) -> Bool { ["parallel", "resistor", "resistorcolors"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        if name.equalsIgnoreCase("parallel") { if count < 1 || count > 16 { throw CalcError.format("parallel expects 1–16 resistance arguments or a list") } }
        else if count < 1 || count > 3 { throw CalcError.format("\(name) expects resistance, optional tolerance and optional significant digits") }
    }
    static func markingAssumption(_ value: ResistorValue) throws -> String { throw notPorted("resistor markings") }
    static func nominalAssumption(_ value: ResistorValue) throws -> String { throw notPorted("resistor markings") }
    /// Keeps the result unless the electrical port says otherwise (C# PreferElectricalUnit).
    static func preferElectricalUnit(_ left: SheetValue, _ right: SheetValue, _ result: SheetValue) throws -> SheetValue { result }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) {}
    func parallel(_ args: [SheetValue]) throws -> SheetValue { throw notPorted("parallel resistance") }
    func encode(_ args: [SheetValue], _ colours: Bool) throws -> ResistorValue { throw notPorted("resistor markings") }
    func decode(_ bands: [String]) throws -> ResistorValue { throw notPorted("resistor markings") }
}
final class HelperArithmetic {
    static let fuelUnits = "mpg is the US gallon (3.785411784 L), mpg uk the imperial gallon (4.54609 L); l/100km and mpg are reciprocal, so 235.2146 / (l/100km) = US mpg"
    static func isFunction(_ name: String) -> Bool { name.equalsIgnoreCase("bmi") }
    static func validateArity(_ name: String, _ count: Int) throws { if count != 2 { throw CalcError.format(name + " expects a mass and a height") } }
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ context: EvaluationContext, _ reads: ContextReads, _ token: CancellationToken) {}
    func evaluate(_ expression: HelperExpression, _ inputs: [SheetValue]) throws -> (value: SheetValue, operation: String, assumption: String) { throw notPorted("practical helpers") }
    func function(_ name: String, _ args: [SheetValue]) throws -> (value: SheetValue, operation: String, assumption: String) { throw notPorted("BMI") }
}
extension ExpressionParser {
    func tryHelper() throws -> Expression? { nil }
    /// C# StartsHelper: TryHelper succeeds and consumes every token; errors mean no.
    func startsHelper() -> Bool { (try? tryHelper()).flatMap { $0 } != nil && position == tokens.count }
    func tryIngredientSuffix(_ expression: inout Expression) throws -> Bool { false }
    func tryCountSuffix(_ expression: inout Expression) throws -> Bool { false }
    func tryGrades() throws -> Expression? { nil }
    func tryChemistryAtom() throws -> Expression? { nil }
    func tryChemistrySuffix(_ expression: inout Expression) throws -> Bool { false }
    func tryResistorLiteral() throws -> Expression? { nil }
}
