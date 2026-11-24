import Foundation

enum UnitParser {
    /// `l/100km` is one fuel-consumption unit, not litres divided by a hundred kilometres; the magnitude is the same.
    private static func tryLitresPer100Km(_ tokens: [Token], _ start: Int, _ names: NetHashSet<String>?) -> Bool {
        guard start + 3 < tokens.count, tokens[start].kind == .name, names?.contains(tokens[start].text) != true,
              let litre = UnitCatalog.tryGet(tokens[start].text), litre.id == "L",
              tokens[start + 1].text == "/", tokens[start + 2].kind == .number, tokens[start + 2].text == "100", tokens[start + 3].kind == .name,
              names?.contains(tokens[start + 3].text) != true, let kilometre = UnitCatalog.tryGet(tokens[start + 3].text), kilometre.id == "km" else { return false }
        return true
    }
    static func tryParse(_ tokens: [Token], _ position: inout Int, _ names: NetHashSet<String>?) throws -> UnitExpression? {
        var cursor = position, factors = 0
        func atom() throws -> UnitExpression? {
            let start = cursor; var prefixPower = 1
            if cursor < tokens.count, ["sq", "square", "cubic"].contains(tokens[cursor].text.netLower) {
                prefixPower = tokens[cursor].text.equalsIgnoreCase("cubic") ? 3 : 2; cursor += 1
            }
            guard cursor < tokens.count, tokens[cursor].kind == .name, names?.contains(tokens[cursor].text) != true,
                  !(cursor + 1 < tokens.count && tokens[cursor + 1].text == "(" && tokens[cursor + 1].joinedToPrevious),
                  var result = try UnitCatalog.tryToken(tokens[cursor].text) else { cursor = start; return nil }
            cursor += 1
            if tokens[cursor - 1].text.equalsIgnoreCase("mpg") && cursor < tokens.count && tokens[cursor].kind == .name && names?.contains(tokens[cursor].text) != true &&
                ["uk", "imp", "imperial", "us"].contains(tokens[cursor].text.netLower) {
                result = try .single(UnitCatalog.byId(tokens[cursor].text.netLower == "us" ? "mpg" : "mpguk")); cursor += 1
            }
            if prefixPower != 1 { result = try result.power(Rational(prefixPower)) }
            if cursor < tokens.count && tokens[cursor].text == "^" {
                cursor += 1; var sign = 1
                if cursor < tokens.count && (tokens[cursor].text == "+" || tokens[cursor].text == "-") { if tokens[cursor].text == "-" { sign = -1 }; cursor += 1 }
                if cursor >= tokens.count || tokens[cursor].kind != .number { throw CalcError.format("Unit power requires an integer") }
                let exponent = try Rational.parse(tokens[cursor].text); cursor += 1
                if !exponent.denominator.isOne || exponent.numerator.magnitude > 16 { throw CalcError.arithmetic("Unit power must be an integer from -16 to 16") }
                result = try result.power(Rational(BigInt(sign) * exponent.numerator))
            }
            factors += 1
            if factors > 16 { throw CalcError.arithmetic("Unit expression limit exceeded") }
            return result
        }
        if tryLitresPer100Km(tokens, cursor, names) { position = cursor + 4; return try .single(UnitCatalog.byId("l100km")) }
        let reciprocal = cursor < tokens.count && (tokens[cursor].text == "/" || tokens[cursor].text.equalsIgnoreCase("per"))
        if reciprocal { cursor += 1 }
        guard var unit = try atom() else { return nil }
        if reciprocal { unit = try unit.power(Rational(-1)) }
        while cursor + 1 < tokens.count && (tokens[cursor].text == "*" || tokens[cursor].text == "/" || tokens[cursor].text.equalsIgnoreCase("per")) {
            let separator = cursor; let sign = tokens[cursor].text == "*" ? 1 : -1; cursor += 1
            guard let next = try atom() else { cursor = separator; break }
            unit = try unit.combine(next, sign)
        }
        position = cursor; return unit
    }
}
