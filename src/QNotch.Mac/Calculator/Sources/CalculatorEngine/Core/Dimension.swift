/// SI base dimensions plus information; exponents are bounded independently of magnitude.
struct Dimension: Hashable {
    var length = 0, mass = 0, time = 0, current = 0, temperature = 0, amount = 0, luminousIntensity = 0, information = 0
    static let none = Dimension()
    init() {}
    init(_ l: Int, _ m: Int, _ t: Int, _ c: Int, _ k: Int, _ a: Int, _ j: Int, _ i: Int) {
        length = l; mass = m; time = t; current = c; temperature = k; amount = a; luminousIntensity = j; information = i
    }
    var components: [Int] { [length, mass, time, current, temperature, amount, luminousIntensity, information] }
    static func from(_ values: [Int]) throws -> Dimension {
        if values.count != 8 || values.contains(where: { abs($0) > 16 }) { throw CalcError.arithmetic("Dimension exponent limit exceeded") }
        return Dimension(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7])
    }
    func combine(_ other: Dimension, _ sign: Int) throws -> Dimension { try .from(zip(components, other.components).map { $0 + sign * $1 }) }
    func power(_ exponent: Rational) throws -> Dimension {
        let values = try components.map { try Rational($0) * exponent }
        if values.contains(where: { !$0.denominator.isOne || $0.numerator.magnitude > 16 }) {
            throw CalcError.arithmetic("Quantity power must have bounded integer dimensions")
        }
        return try .from(values.map { $0.numerator.intValue! })
    }
}
