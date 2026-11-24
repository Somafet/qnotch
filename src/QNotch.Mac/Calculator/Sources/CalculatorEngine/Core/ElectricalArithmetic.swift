import Foundation

/// Parallel resistance and commercial resistor colour codes.
final class ElectricalArithmetic {
    static let parallelAssumption = "Passive DC parallel resistance; reciprocal sum 1 / sum(1/R); zero is an ideal short; nonnegative finite inputs; no frequency/temperature/lead or tolerance interval model"
    static let resistanceDimension = Dimension(2, 1, -3, -2, 0, 0, 0, 0)
    /// A product or ratio of electrical quantities shows in ohm, A, V or W rather than in base units.
    static func preferElectricalUnit(_ left: SheetValue, _ right: SheetValue, _ result: SheetValue) throws -> SheetValue {
        guard case .number(let l) = left, case .number(let r) = right, let leftUnit = l.unit, let rightUnit = r.unit,
              !(leftUnit.dimension.current == 0 && rightUnit.dimension.current == 0), case .number(let number) = result, let unit = number.unit else { return result }
        let id: String?
        switch unit.dimension {
        case resistanceDimension: id = "ohm"
        case Dimension(0, 0, 0, 1, 0, 0, 0, 0): id = "A"
        case Dimension(2, 1, -3, -1, 0, 0, 0, 0): id = "V"
        case Dimension(2, 1, -3, 0, 0, 0, 0, 0): id = "W"
        default: id = nil
        }
        guard let id else { return result }
        let electrical = try UnitExpression.single(UnitCatalog.byId(id))
        return .number(number.with { $0.unit = electrical })
    }
    static func isFunction(_ name: String) -> Bool { ["parallel", "resistor", "resistorcolors"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        if name.equalsIgnoreCase("parallel") { if count < 1 || count > 16 { throw CalcError.format("parallel expects 1–16 resistance arguments or a list") } }
        else if count < 1 || count > 3 { throw CalcError.format("\(name) expects resistance, optional tolerance and optional significant digits") }
    }
    let math: ExactArithmetic, budget: ExecutionBudget, token: CancellationToken
    init(_ math: ExactArithmetic, _ budget: ExecutionBudget, _ token: CancellationToken) { self.math = math; self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }

    static func markingAssumption(_ value: ResistorValue) throws -> String {
        "Commercial \(value.significantDigits)-digit marking; ±\(try value.tolerance * Rational(100))% of nominal; resistance range \(try value.minimumOhms)–\(try value.maximumOhms) ohm; " +
            "\(ResistorColorCatalog.ruleId); \(ResistorColorCatalog.source); caller supplies band order; not a measured value or power rating; arithmetic uses nominal resistance and does not propagate tolerance intervals"
    }
    static func nominalAssumption(_ value: ResistorValue) throws -> String {
        "Nominal resistance used from \(value.bands.joined(separator: " ")) (±\(try value.tolerance * Rational(100))%); component tolerance intervals are not propagated through arithmetic"
    }
    private static func power10(_ exponent: Int) throws -> Rational { exponent >= 0 ? try Rational(BigInt.pow(10, exponent)) : try Rational(.one, BigInt.pow(10, -exponent)) }

    func decode(_ bands: [String], _ colors: Bool = false) throws -> ResistorValue {
        if bands.count < 3 || bands.count > 5 { throw CalcError.arithmetic("Resistor requires three, four or five commercial bands") }
        let definitions = try bands.map { name in
            guard let color = ResistorColorCatalog.tryGet(name) else { throw CalcError.arithmetic("Unknown resistor color") }
            return color
        }
        let digits = bands.count == 5 ? 3 : 2; var significant = 0
        for i in 0..<digits {
            try step()
            guard let digit = definitions[i].digit else { throw CalcError.arithmetic("Gold/silver cannot be significant-digit bands") }
            if i == 0 && digit == 0 { throw CalcError.arithmetic("First significant band cannot be black; zero-ohm jumper markings are not implemented") }
            significant = significant * 10 + digit
        }
        let tolerance: Rational
        if bands.count == 3 { tolerance = try Rational(1, 5) }
        else if let marked = definitions[definitions.count - 1].tolerance { tolerance = marked }
        else { throw CalcError.arithmetic("Invalid commercial tolerance band") }
        let nominal = try Rational(significant) * ElectricalArithmetic.power10(definitions[digits].multiplierExponent)
        return try ResistorValue(nominal, tolerance, definitions.map(\.name), digits, colors)
    }
    private static func resistance(_ input: SheetValue, _ allowBare: Bool) throws -> NumericValue {
        let number: NumericValue
        if case .resistor(let resistor) = input { number = resistor.nominal } else { number = try input.number }
        if number.isPercentage || number.unit?.isTemperaturePoint == true || number.unit == nil && !allowBare || number.unit != nil && number.unit!.dimension != resistanceDimension {
            throw CalcError.arithmetic("Expected a resistance quantity (or an explicitly allowed bare ohm magnitude)")
        }
        return number
    }
    func encode(_ args: [SheetValue], _ colors: Bool) throws -> ResistorValue {
        let number = try ElectricalArithmetic.resistance(args[0], true)
        if try !number.isRational || number.isApproximate || number.exact.rational.sign <= 0 { throw CalcError.arithmetic("Color encoding requires a positive exact rational resistance") }
        let ohms = try number.exact.rational
        var original: ResistorValue?
        if case .resistor(let resistor) = args[0] { original = resistor }
        var tolerance = try original?.tolerance ?? Rational(1, 5)
        if args.count >= 2 {
            let value = try args[1].number
            if value.unit != nil || !value.isRational || value.isApproximate { throw CalcError.arithmetic("Tolerance requires an exact percentage or percent number") }
            tolerance = value.isPercentage ? try value.scalar : try value.scalar / Rational(100)
        }
        let toleranceColor = ResistorColorCatalog.colors.first { $0.tolerance == tolerance }
        if try tolerance != Rational(1, 5) && toleranceColor == nil { throw CalcError.arithmetic("Unsupported commercial tolerance; use 20, 10, 5, 2, 1, 0.5, 0.25, 0.1 or 0.05 percent") }
        var requestedDigits = original?.significantDigits
        if args.count == 3 {
            let digits = try args[2].number
            if try digits.unit != nil || digits.isPercentage || !digits.isRational || digits.isApproximate || digits.scalar != Rational(2) && digits.scalar != Rational(3) {
                throw CalcError.arithmetic("Significant digits must be exactly 2 or 3")
            }
            requestedDigits = try digits.scalar.numerator.intValue!
        }
        for digits in requestedDigits.map({ [$0] }) ?? [2, 3] {
            if digits == 3 && toleranceColor == nil { continue } // A four-band three-digit code without tolerance is ambiguous.
            for exponent in -2...9 {
                try step(); let significant = try ohms / ElectricalArithmetic.power10(exponent)
                if !significant.denominator.isOne || significant.numerator < BigInt.pow(10, digits - 1) || significant.numerator >= BigInt.pow(10, digits) { continue }
                var bands = significant.numerator.description.utf16.map { character in ResistorColorCatalog.colors.first { $0.digit == Int(character) - 48 }!.name }
                bands.append(ResistorColorCatalog.colors.first { $0.multiplierExponent == exponent }!.name)
                if let toleranceColor { bands.append(toleranceColor.name) }
                return try decode(bands, colors)
            }
        }
        throw CalcError.arithmetic("Resistance has no exact supported two/three-digit color code; provide a supported tolerance for three digits; values are never rounded to a preferred series")
    }
    func parallel(_ args: [SheetValue]) throws -> SheetValue {
        var inputs: [SheetValue] = []
        func add(_ value: SheetValue) throws {
            try step()
            if inputs.count == SheetList.maxItems { throw CalcError.arithmetic("Parallel network exceeds 1024 branches") }
            inputs.append(value)
        }
        for arg in args {
            if case .list(let list) = arg { for item in list.values { try add(item) } } else { try add(arg) }
        }
        if inputs.isEmpty { throw CalcError.arithmetic("Parallel resistance requires at least one input") }
        let first = try ElectricalArithmetic.resistance(inputs[0], true); let unitful = first.unit != nil
        var reciprocal = ExactNumber.zero, zero = false, approximate = false, numbers: [NumericValue] = []
        for input in inputs {
            try step(); let number = try ElectricalArithmetic.resistance(input, true)
            if (number.unit != nil) != unitful { throw CalcError.arithmetic("Do not mix bare and unit-bearing parallel resistances") }
            let sign = try math.sign(number.exact)
            if sign < 0 { throw CalcError.arithmetic("Passive parallel resistance cannot be negative") }
            approximate = approximate || number.isApproximate
            if sign == 0 { zero = true }
            numbers.append(number)
        }
        if !zero {
            for number in numbers {
                try step(); let conductance = try math.divide(ExactArithmetic.one, number.exact)
                try step(); reciprocal = try math.add(reciprocal, conductance)
            }
        }
        try step(); let exact = zero ? ExactNumber.zero : try math.divide(ExactArithmetic.one, reciprocal)
        return .number(first.with { $0.exact = exact; $0.isApproximate = approximate; $0.displayDecimalPlaces = 4; $0.useCompoundDuration = false; $0.useDaysInDuration = false })
    }
}
