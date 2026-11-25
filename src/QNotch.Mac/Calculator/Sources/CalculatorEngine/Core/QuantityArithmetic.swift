import Foundation

final class QuantityArithmetic {
    let math: ExactArithmetic
    init(_ math: ExactArithmetic) { self.math = math }
    private static func plain(_ value: NumericValue) throws { if value.unit != nil { throw CalcError.arithmetic("Expected a dimensionless value") } }
    private static func linear(_ value: NumericValue) throws {
        if value.unit?.isTemperaturePoint == true { throw CalcError.arithmetic("Use temperature differences for scaling, products and ratios") }
    }
    private static func compatible(_ a: NumericValue, _ b: NumericValue) throws {
        if a.unit?.dimension != b.unit?.dimension { throw CalcError.arithmetic("Incompatible dimensions") }
        try compatibleKinds(a.quantityKind, b.quantityKind)
    }
    private static func compatibleKinds(_ a: String, _ b: String) throws {
        if !a.isEmpty && !b.isEmpty && a != b { throw CalcError.arithmetic("Incompatible quantity kinds") }
    }
    func displayMagnitude(_ value: NumericValue) throws -> ExactNumber {
        guard let unit = value.unit else { return value.exact }
        return try math.scale(math.subtract(value.exact, ExactNumber(unit.offset)), Rational.one / unit.factor)
    }
    func attach(_ value: NumericValue, _ unit: UnitExpression) throws -> NumericValue {
        try QuantityArithmetic.plain(value)
        if value.isPercentage { throw CalcError.arithmetic("A percentage cannot be a unit magnitude") }
        return try checked(QuantityArithmetic.metadata(QuantityArithmetic.result(math.add(math.scale(value.exact, unit.factor), ExactNumber(unit.offset)), unit), value))
    }
    private func checked(_ value: NumericValue) throws -> NumericValue {
        if value.unit?.isTemperaturePoint == true, try math.sign(value.exact) < 0 { throw CalcError.arithmetic("Temperature is below absolute zero") }
        if value.quantityKind == TimeArithmetic.workedKind && value.unit?.dimension == TimeArithmetic.timeDimension, try math.sign(value.exact) < 0 {
            throw CalcError.arithmetic("Deductions exceed the worked interval")
        }
        return value
    }
    func convert(_ value: NumericValue, _ unit: UnitExpression) throws -> NumericValue {
        if let from = value.unit, from.dimension != unit.dimension, case let form = from.fuelForm(), form != 0, unit.fuelForm() == -form {
            if try math.sign(value.exact) <= 0 { throw CalcError.arithmetic("Fuel consumption and economy must be positive to convert") }
            let inverse = try math.divide(ExactArithmetic.one, value.exact)
            return value.with { $0.exact = inverse; $0.unit = unit; $0.quantityKind = ""; $0.displayDecimalPlaces = 2 }
        }
        guard let from = value.unit, from.dimension == unit.dimension else { throw CalcError.arithmetic("Incompatible conversion dimensions") }
        try QuantityArithmetic.compatibleKinds(value.quantityKind, unit.kind)
        if from.isTemperaturePoint != unit.isTemperaturePoint { throw CalcError.arithmetic("Cannot convert a temperature point to a difference") }
        return value.with {
            $0.unit = unit; $0.quantityKind = value.quantityKind.isEmpty ? unit.kind : value.quantityKind; $0.useCompoundDuration = false; $0.useDaysInDuration = false
            $0.displayDecimalPlaces = unit.fuelForm() != 0 ? 2 : value.displayDecimalPlaces
        }
    }
    func scale(_ value: NumericValue, _ factor: Rational) throws -> NumericValue {
        try QuantityArithmetic.linear(value)
        let scaled = try math.scale(value.exact, factor)
        return try checked(value.with { $0.exact = scaled })
    }
    func unary(_ operation: String, _ value: NumericValue) throws -> NumericValue {
        if operation == "+" { return value }
        if operation == "-" {
            if let unit = value.unit, unit.isTemperaturePoint { return try attach(NumericValue(math.negate(displayMagnitude(value))), unit) }
            let negated = try math.negate(value.exact)
            return try checked(value.with { $0.exact = negated })
        }
        try QuantityArithmetic.plain(value)
        if operation == "%" { return QuantityArithmetic.metadata(NumericValue(try math.scale(value.exact, Rational(1, 100)), isPercentage: true), value) }
        throw CalcError.format("Unknown operator")
    }
    func binary(_ operation: String, _ left: NumericValue, _ right: NumericValue) throws -> NumericValue {
        QuantityArithmetic.metadata(try binaryCore(operation, left, right), left, right)
    }
    private func binaryCore(_ operation: String, _ left: NumericValue, _ right: NumericValue) throws -> NumericValue {
        if operation == "+" || operation == "-" {
            if !left.isPercentage && right.isPercentage {
                try QuantityArithmetic.linear(left)
                let delta = try math.multiply(left.exact, right.exact)
                let exact = operation == "+" ? try math.add(left.exact, delta) : try math.subtract(left.exact, delta)
                return try checked(left.with { $0.exact = exact })
            }
            try QuantityArithmetic.compatible(left, right)
            let lp = left.unit?.isTemperaturePoint == true, rp = right.unit?.isTemperaturePoint == true
            if lp && rp && operation == "+" || !lp && rp && operation == "-" { throw CalcError.arithmetic("Invalid temperature-point arithmetic") }
            let unit = lp && rp ? try left.unit!.delta() : rp ? right.unit : left.unit
            let result = operation == "+" ? try math.add(left.exact, right.exact) : try math.subtract(left.exact, right.exact)
            guard let unit else { return try checked(NumericValue(result, isPercentage: left.isPercentage && right.isPercentage)) }
            return try checked(NumericValue(result, unit: unit).with {
                $0.quantityKind = left.quantityKind.isEmpty ? right.quantityKind : left.quantityKind
                $0.useCompoundDuration = left.useCompoundDuration || right.useCompoundDuration; $0.useDaysInDuration = left.useDaysInDuration || right.useDaysInDuration
            })
        }
        if operation == "^" {
            try QuantityArithmetic.plain(right)
            let exponent = try right.scalar; let unit = try left.unit?.power(exponent)
            let powered = QuantityArithmetic.result(exponent.denominator == 2 && left.isApproximate ? try math.power(root(left), Rational(exponent.numerator, .one)) : try math.power(left.exact, exponent), unit)
            return exponent == .one ? powered.with { $0.quantityKind = left.quantityKind } : powered
        }
        try QuantityArithmetic.linear(left); try QuantityArithmetic.linear(right)
        let divide = operation == "/"
        if !divide && operation != "*" && operation != "of" { throw CalcError.format("Unknown operator") }
        let combined: UnitExpression? = left.unit == nil ? (divide ? try right.unit?.power(Rational(-1)) : right.unit) :
            right.unit == nil ? left.unit : try left.unit!.combine(right.unit!, divide ? -1 : 1)
        let exact = divide ? try math.divide(left.exact, right.exact) : try math.multiply(left.exact, right.exact)
        var answer = combined == nil ? NumericValue(exact, isPercentage: divide && left.isPercentage && !right.isPercentage) : QuantityArithmetic.result(exact, combined)
        if answer.unit != nil && right.unit == nil { answer.quantityKind = left.quantityKind }
        if answer.unit != nil && left.unit == nil && !divide { answer.quantityKind = right.quantityKind }
        if answer.unit?.dimension == TimeArithmetic.timeDimension {
            answer.useCompoundDuration = left.useCompoundDuration || right.useCompoundDuration; answer.useDaysInDuration = left.useDaysInDuration || right.useDaysInDuration
        }
        return try checked(answer)
    }
    /// An approximate input has no exact radical worth extracting; its root stays a marked double.
    private func root(_ value: NumericValue) throws -> ExactNumber {
        if value.isApproximate, try math.sign(value.exact) > 0 { return ExactNumber(try FormulaNumbers.fromDouble(FormulaNumbers.toDouble(value.exact).squareRoot())) }
        return try math.squareRoot(value.exact)
    }
    private static func result(_ value: ExactNumber, _ unit: UnitExpression?) -> NumericValue {
        guard let unit, unit.dimension != .none else { return NumericValue(value) }
        return NumericValue(value, unit: unit)
    }
    func function(_ name: String, _ args: [NumericValue]) throws -> NumericValue { QuantityArithmetic.metadata(try functionCore(name, args), args) }
    private func functionCore(_ name: String, _ args: [NumericValue]) throws -> NumericValue {
        let key = name.netLower; let count = key == "abs" || key == "sqrt" ? 1 : 2
        if args.count != count { throw CalcError.format("\(name) expects \(count) argument(s)") }
        let a = args[0], b = count == 2 ? args[1] : NumericValue(Rational.one)
        if key == "sqrt" { return QuantityArithmetic.result(try root(a), try a.unit?.power(Rational(1, 2))) }
        if key == "abs" {
            try QuantityArithmetic.linear(a)
            let absolute = try math.sign(a.exact) < 0 ? try math.negate(a.exact) : a.exact
            return a.with { $0.exact = absolute }
        }
        if key == "whole" || key == "beforediscount" {
            try QuantityArithmetic.linear(a); try QuantityArithmetic.plain(b)
            if !b.isPercentage { throw CalcError.format("Expected percentage") }
            let exact = try math.divide(a.exact, key == "whole" ? b.exact : try math.subtract(ExactArithmetic.one, b.exact))
            return a.with { $0.exact = exact; $0.isPercentage = false }
        }
        try QuantityArithmetic.compatible(a, b); try QuantityArithmetic.linear(a); try QuantityArithmetic.linear(b)
        switch key {
        case "share": return NumericValue(try math.divide(a.exact, b.exact), isPercentage: true)
        case "change", "markup": return NumericValue(try math.divide(math.subtract(b.exact, a.exact), a.exact), isPercentage: true)
        case "margin": return NumericValue(try math.divide(math.subtract(b.exact, a.exact), b.exact), isPercentage: true)
        default: throw CalcError.format("Unknown function: \(name)")
        }
    }
    func aggregate(_ values: [NumericValue], _ average: Bool, _ token: CancellationToken) throws -> NumericValue {
        guard let first = values.first else { throw CalcError.arithmetic("No values to aggregate") }
        var sum = ExactNumber.zero; var kind = first.quantityKind
        for value in values {
            try token.throwIfCancellationRequested(); try QuantityArithmetic.compatible(first, value)
            try QuantityArithmetic.compatibleKinds(kind, value.quantityKind)
            if kind.isEmpty { kind = value.quantityKind }
            if first.unit?.isTemperaturePoint != value.unit?.isTemperaturePoint { throw CalcError.arithmetic("Cannot mix temperature points and differences in an aggregate") }
            if !average { try QuantityArithmetic.linear(value) }
            sum = try math.add(sum, value.exact)
        }
        if average { sum = try math.scale(sum, Rational(BigInt(1), BigInt(values.count))) }
        if let unit = first.unit {
            return QuantityArithmetic.metadata(try checked(NumericValue(sum, unit: unit).with {
                $0.quantityKind = kind; $0.useCompoundDuration = values.contains { $0.useCompoundDuration }; $0.useDaysInDuration = values.contains { $0.useDaysInDuration }
            }), values)
        }
        return QuantityArithmetic.metadata(NumericValue(sum, isPercentage: values.allSatisfy { $0.isPercentage }), values)
    }
    func round(_ kind: RoundingKind, _ value: NumericValue, _ precision: NumericValue, _ token: CancellationToken) throws -> NumericValue {
        try roundCore(kind, value, precision, token).with { $0.isApproximate = value.isApproximate || precision.isApproximate; $0.displayDecimalPlaces = nil }
    }
    private func roundCore(_ kind: RoundingKind, _ value: NumericValue, _ precision: NumericValue, _ token: CancellationToken) throws -> NumericValue {
        guard let unit = value.unit else { try QuantityArithmetic.plain(precision); return try ExactRounding.apply(kind, value, precision, token, math) }
        var quantum = precision
        if kind == .increment {
            try QuantityArithmetic.compatible(value, precision); try QuantityArithmetic.linear(precision)
            quantum = NumericValue(try math.scale(precision.exact, Rational.one / unit.factor))
        } else { try QuantityArithmetic.plain(precision) }
        let rounded = try ExactRounding.apply(kind, NumericValue(displayMagnitude(value)), quantum, token, math)
        return try checked(attach(rounded, unit).with { $0.quantityKind = value.quantityKind; $0.useCompoundDuration = value.useCompoundDuration; $0.useDaysInDuration = value.useDaysInDuration })
    }
    static func metadata(_ result: NumericValue, _ inputs: [NumericValue]) -> NumericValue {
        var approximate = result.isApproximate, places = result.displayDecimalPlaces, notation = result.useConstantNotation
        for value in inputs {
            approximate = approximate || value.isApproximate; notation = notation || value.useConstantNotation
            if let count = value.displayDecimalPlaces { places = max(places ?? 0, count) }
        }
        return result.with { $0.isApproximate = approximate; $0.displayDecimalPlaces = places; $0.useConstantNotation = notation }
    }
    static func metadata(_ result: NumericValue, _ first: NumericValue, _ second: NumericValue = NumericValue()) -> NumericValue {
        result.with {
            $0.isApproximate = result.isApproximate || first.isApproximate || second.isApproximate
            $0.useConstantNotation = result.useConstantNotation || first.useConstantNotation || second.useConstantNotation
            $0.displayDecimalPlaces = result.displayDecimalPlaces == nil && first.displayDecimalPlaces == nil && second.displayDecimalPlaces == nil ? nil :
                max(result.displayDecimalPlaces ?? 0, max(first.displayDecimalPlaces ?? 0, second.displayDecimalPlaces ?? 0))
        }
    }
}
