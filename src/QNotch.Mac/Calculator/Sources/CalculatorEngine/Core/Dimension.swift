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
    /// Not optimized: Swift 6.2.3's CopyPropagation pass fails its ownership check on this function in release builds (compiler crash, signal 6).
    @_optimize(none)
    func power(_ exponent: Rational) throws -> Dimension {
        // A plain loop: the map-with-throwing-closure form crashed the Swift 6.0 optimizer (CopyPropagation) in the app build.
        var powers: [Int] = []
        powers.reserveCapacity(8)
        for value in components {
            let product = try Rational(value) * exponent
            if !product.denominator.isOne || product.numerator.magnitude > 16 { throw CalcError.arithmetic("Quantity power must have bounded integer dimensions") }
            powers.append(product.numerator.intValue!)
        }
        return try .from(powers)
    }
}
