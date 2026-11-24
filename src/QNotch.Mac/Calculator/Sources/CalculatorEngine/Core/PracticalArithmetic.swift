import Foundation

/// Engineering notation and weighted grades.
final class PracticalArithmetic {
    static let engineeringAssumption = "Engineering display: exponent multiple of three, six significant figures and available decimal SI units; original exact magnitude and approximation provenance retained; copied expression reconstructs the represented value"
    static func isFunction(_ name: String) -> Bool { ["engineering", "weightedmean", "grades", "molarmass", "moles", "massof"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let key = name.netLower
        if key == "engineering" { if count < 1 || count > 2 { throw CalcError.format("engineering expects a value and optional represented-approximation flag") } }
        else if count != (key == "molarmass" ? 1 : 2) { throw CalcError.format("\(name) has an invalid argument count") }
    }
    let math: ExactArithmetic, budget: ExecutionBudget, token: CancellationToken
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) { self.math = math; self.budget = budget; self.token = token }

    func engineering(_ args: [SheetValue]) throws -> SheetValue {
        try PracticalArithmetic.validateArity("engineering", args.count); var number = try args[0].number
        if args.count == 2 {
            let flag = try args[1].number
            if try flag.unit != nil || flag.isPercentage || flag.isApproximate || !flag.isRational || flag.scalar != .zero && flag.scalar != .one {
                throw CalcError.arithmetic("Represented-approximation flag must be exact 0 or 1")
            }
            let represented = try flag.scalar == .one
            number = number.with { $0.isApproximate = $0.isApproximate || represented }
        }
        return .engineering(try EngineeringValue(number, math, budget, token))
    }
    func grades(_ scores: [SheetValue], _ weights: [SheetValue]) throws -> SheetValue {
        if scores.count < 1 || scores.count > SheetList.maxItems || scores.count != weights.count {
            throw CalcError.arithmetic("Weighted grades require equal nonempty score/weight lists of at most 1024 entries")
        }
        var sum = ExactNumber.zero, total = ExactNumber.zero, approximate = false
        let percentScores = scores[0].isPercentage, percentWeights = weights[0].isPercentage
        for i in 0..<scores.count {
            try budget.step(token); let score = try scores[i].number, weight = try weights[i].number
            if try score.unit != nil || weight.unit != nil || !weight.isRational || weight.exact.rational.sign < 0 || score.isPercentage != percentScores || weight.isPercentage != percentWeights {
                throw CalcError.arithmetic("Grades require dimensionless scores, nonnegative rational weights and consistent percentage types")
            }
            approximate = approximate || score.isApproximate || weight.isApproximate
            try budget.step(token); let product = try math.multiply(score.exact, weight.exact)
            try budget.step(token); sum = try math.add(sum, product)
            try budget.step(token); total = try math.add(total, weight.exact)
        }
        if total.isZero { throw CalcError.arithmetic("Total grade weight must be positive") }
        try budget.step(token)
        return .number(NumericValue(try math.divide(sum, total), isPercentage: percentScores).with { $0.isApproximate = approximate; $0.displayDecimalPlaces = 4 })
    }
}
