import Foundation

/// Colours, Unix permissions, aspect ratios and Unicode scalars (C# DeveloperArithmetic).
final class DeveloperArithmetic {
    static let convention = "Exact represented helper values; conversions retain stored data; permission and Unicode queries do not inspect or change OS state"
    static func isFunction(_ name: String) -> Bool {
        ["color", "colour", "rgb", "rgba", "hsl", "hsla", "colourhex", "chmod", "modebits", "modeoctal", "aspect", "asratio", "unicode", "codepoint", "chr"].contains(name.netLower)
    }
    static func isTextFunction(_ name: String) -> Bool { ["color", "colour", "chmod", "unicode"].contains(name.netLower) }
    static func validateArity(_ name: String, _ count: Int) throws {
        let valid: Bool
        switch name.netLower {
        case "rgb", "hsl": valid = count == 1 || count == 3 || count == 4
        case "rgba", "hsla": valid = count == 4
        case "aspect": valid = count == 2
        default: valid = count == 1
        }
        if !valid { throw CalcError.format("\(name) has an invalid argument count") }
    }
    private let budget: ExecutionBudget
    private let token: CancellationToken
    init(_ budget: ExecutionBudget, _ token: CancellationToken) { self.budget = budget; self.token = token }
    private func step() throws { try budget.step(token) }
    private static func number(_ value: SheetValue) throws -> NumericValue {
        switch value {
        case .integer(let integer): return NumericValue(try Rational(integer.value))
        case .number(let number): return number
        default: throw CalcError.arithmetic("Expected a numeric helper argument")
        }
    }
    private static func scalar(_ value: SheetValue) throws -> Rational {
        let n = try number(value)
        if n.unit != nil || !n.isRational || n.isApproximate { throw CalcError.arithmetic("Expected an exact dimensionless rational") }
        return try n.exact.rational
    }

    func colourLiteral(_ text: String) throws -> SheetValue {
        try step()
        var digits = text.units
        if digits.first == UInt16(ascii: "#") { digits.removeFirst() }
        if ![3, 4, 6, 8].contains(digits.count) || digits.contains(where: { !NetChar.isAsciiHexDigit($0) }) { throw CalcError.format("Expected #RGB, #RGBA, #RRGGBB or #RRGGBBAA") }
        if digits.count <= 4 { digits = digits.flatMap { [$0, $0] } }
        let channels = stride(from: 0, to: digits.count, by: 2).map { Int(digits.string($0, $0 + 2), radix: 16)! }
        return .colour(try ColourValue(try Rational(channels[0], 255), try Rational(channels[1], 255), try Rational(channels[2], 255),
                                       try Rational(channels.count == 4 ? channels[3] : 255, 255), .hex))
    }

    func function(_ name: String, _ args: [SheetValue]) throws -> SheetValue {
        try step(); try DeveloperArithmetic.validateArity(name, args.count); let key = name.netLower
        if key == "color" || key == "colour" { return args[0].kind == .colour ? args[0] : try colourLiteral(try args[0].text.value) }
        if ["rgb", "rgba", "hsl", "hsla", "colourhex"].contains(key) {
            let style: ColourPresentation = key == "rgb" || key == "rgba" ? .rgb : key == "hsl" || key == "hsla" ? .hsl : .hex
            if args.count == 1 { return .colour(try args[0].colour.with(presentation: style)) }
            // A percentage is already a 0…1 fraction; a bare number counts 0…255 (RGB) or 0…100 (HSL).
            func ratio(_ value: SheetValue, _ rgb: Bool) throws -> Rational {
                let n = try DeveloperArithmetic.number(value); let r = try DeveloperArithmetic.scalar(value)
                return n.isPercentage ? r : try r / Rational(rgb ? 255 : 100)
            }
            let alpha = args.count == 4 ? try DeveloperArithmetic.scalar(args[3]) : Rational.one
            if style == .rgb { return .colour(try ColourValue(try ratio(args[0], true), try ratio(args[1], true), try ratio(args[2], true), alpha, style)) }
            if try DeveloperArithmetic.number(args[0]).isPercentage { throw CalcError.arithmetic("Hue is a degree count, not a percentage") }
            let hue = try DeveloperSource.mod(try DeveloperArithmetic.scalar(args[0]), 360); let sat = try ratio(args[1], false); let light = try ratio(args[2], false)
            if sat.numerator < 0 || sat.numerator > sat.denominator || light.numerator < 0 || light.numerator > light.denominator { throw CalcError.arithmetic("HSL percentages must be 0–100%") }
            let one = Rational.one
            let c = try (one - (try Rational(2) * light - one).abs) * sat; let hp = try hue / Rational(60)
            let x = try c * (one - (try DeveloperSource.mod(hp, 2) - one).abs); let m = try light - c / Rational(2)
            let sector = (hp.numerator / hp.denominator).intValue!; let z = Rational.zero
            let (r, g, b): (Rational, Rational, Rational)
            switch sector { case 0: (r, g, b) = (c, x, z); case 1: (r, g, b) = (x, c, z); case 2: (r, g, b) = (z, c, x); case 3: (r, g, b) = (z, x, c); case 4: (r, g, b) = (x, z, c); default: (r, g, b) = (c, z, x) }
            return .colour(try ColourValue(try r + m, try g + m, try b + m, alpha, style))
        }
        if key == "chmod" {
            if case .permission(let permission) = args[0] { return .permission(try PermissionValue(permission.bits, !permission.showOctal)) }
            if args[0].kind == .integer {
                let bits = try IntegerArithmetic.require(args[0])
                if bits < 0 || bits > 4095 { throw CalcError.arithmetic("Permission bits out of range") }
                return .permission(try PermissionValue(bits.intValue!))
            }
            let text = args[0].kind == .text ? try args[0].text.value : try IntegerArithmetic.require(args[0]).description
            let u = text.units
            if u.count >= 1 && u.count <= 4 && u.allSatisfy({ $0 >= 48 && $0 <= 55 }) { return .permission(try PermissionValue(Int(text, radix: 8)!)) }
            if u.count != 9 { throw CalcError.format("Expected octal digits or nine symbolic permission characters") }
            var mode = 0
            for group in 0..<3 {
                try step(); let p = group * 3; let r = u[p], w = u[p + 1], e = u[p + 2]
                func isAny(_ c: UInt16, _ options: String) -> Bool { options.utf16.contains(c) }
                if !isAny(r, "r-") || !isAny(w, "w-") || !(group < 2 ? isAny(e, "x-sS") : isAny(e, "x-tT")) { throw CalcError.format("Invalid symbolic permission character") }
                let n = (r == UInt16(ascii: "r") ? 4 : 0) + (w == UInt16(ascii: "w") ? 2 : 0) + (isAny(e, "xst") ? 1 : 0); mode |= n << (6 - group * 3)
                if isAny(e, "sStT") { mode |= group == 0 ? 2048 : group == 1 ? 1024 : 512 }
            }
            return .permission(try PermissionValue(mode, true))
        }
        if key == "modebits" { return SheetValue(Rational(try args[0].permission.bits)) }
        if key == "modeoctal" { return .permission(try PermissionValue(try args[0].permission.bits, true)) }
        if key == "asratio" {
            if args[0].isPercentage { throw CalcError.arithmetic("Aspect ratio requires an ordinary scalar") }
            return args[0].kind == .aspect ? args[0] : .aspect(try AspectValue(try DeveloperArithmetic.scalar(args[0])))
        }
        if key == "aspect" {
            let w = try DeveloperArithmetic.number(args[0]); let h = try DeveloperArithmetic.number(args[1])
            if w.isPercentage || h.isPercentage || w.isApproximate || h.isApproximate || !w.isRational || !h.isRational || w.unit?.dimension != h.unit?.dimension ||
                w.quantityKind != h.quantityKind || w.unit?.isTemperaturePoint == true || h.unit?.isTemperaturePoint == true {
                throw CalcError.arithmetic("Aspect dimensions must be exact compatible quantities")
            }
            let width = try w.exact.rational, height = try h.exact.rational
            if width.numerator.sign <= 0 || height.numerator.sign <= 0 { throw CalcError.arithmetic("Aspect dimensions must be positive") }
            return .aspect(try AspectValue(try width / height))
        }
        if key == "unicode" {
            if case .unicode(let unicode) = args[0] { return .unicode(try UnicodeValue(unicode.scalars, false)) }
            var values: [Int] = []
            for scalar in try args[0].text.value.unicodeScalars {
                try step()
                if values.count == 256 { throw CalcError.arithmetic("Unicode inspection exceeds 256 scalars") }
                values.append(Int(scalar.value))
            }
            return .unicode(try UnicodeValue(values, false))
        }
        if key == "codepoint" || key == "chr" {
            let cp = try IntegerArithmetic.require(args[0])
            if !DeveloperSource.isScalar(cp) { throw CalcError.arithmetic("Expected a Unicode scalar outside the surrogate range") }
            let value = cp.intValue!
            return key == "chr" ? .text(try TextValue(String(Unicode.Scalar(UInt32(value))!))) : .unicode(try UnicodeValue([value], true))
        }
        throw CalcError.format("Unknown developer helper")
    }
}
