import Foundation

enum EquationSolutionScope: String { case allRealRoots = "AllRealRoots", bracketedRoots = "BracketedRoots", identity = "Identity" }

struct EquationRoot: Hashable {
    let value: NumericValue
    var lower: Rational?
    var upper: Rational?
    init(_ value: NumericValue, _ lower: Rational? = nil, _ upper: Rational? = nil) { self.value = value; self.lower = lower; self.upper = upper }
}

/// Immutable solution set of one real equation. Display, copy and explanation text derive from the retained roots.
///
/// The C# record compares its `Roots` list by reference, so two separately computed results are never equal;
/// equality here is identity to keep the sheet cache's reuse decisions the same.
final class EquationValue: Hashable {
    static let maxRoots = 16
    let variable: String
    let roots: [EquationRoot]
    let scope: EquationSolutionScope
    let method: String
    let summary: String
    let details: String
    let truncated: Bool
    /// True when a from/to domain restricted the reported roots.
    let inDomain: Bool
    var isApproximate: Bool { roots.contains { $0.value.isApproximate } }

    init(_ variable: String, _ roots: [EquationRoot], _ scope: EquationSolutionScope, _ method: String, _ summary: String, truncated: Bool = false, inDomain: Bool = false) throws {
        if roots.count > EquationValue.maxRoots { throw CalcError.arithmetic("Equation result limit exceeded") }
        self.variable = variable; self.roots = roots; self.scope = scope; self.method = method; self.summary = summary; self.truncated = truncated; self.inDomain = inDomain
        let claim: String
        switch scope {
        case .bracketedRoots:
            claim = roots.isEmpty ? "No sign change was found in the search window; this is not proof that no solution exists." :
                (truncated ? "More sign changes exist; narrow the domain with from a to b. " : "") +
                "Bracketed roots in the search window only; roots without a sign change and roots outside the window are not found. No claim of completeness."
        case .identity: claim = "Every real value solves this identity."
        case .allRealRoots: claim = "All distinct real roots in the stated domain; repeated roots appear once. Complex roots are out of scope."
        }
        var lines: [String] = []
        for (i, root) in roots.enumerated() {
            let enclosure = root.lower.map { "; exact enclosure [" + $0.description + ", " + (root.upper?.description ?? "") + "]" } ??
                (root.value.isApproximate ? "; bisection to double precision" : "; exact")
            lines.append("Root \(i + 1): " + (try EquationValue.full(root.value)) + enclosure)
        }
        details = method + "\n" + claim + (roots.isEmpty ? "" : "\n" + lines.joined(separator: "\n"))
        if details.netLength > 16384 { throw CalcError.arithmetic("Equation result limit exceeded") }
    }
    private static func full(_ value: NumericValue) throws -> String { try value.with { $0.isApproximate = false; $0.displayDecimalPlaces = nil }.display }
    private func join(_ format: (NumericValue) throws -> String, _ limit: Int) throws -> String {
        try roots.prefix(limit).map { variable + ($0.value.isApproximate ? " ≈ " : " = ") + (try format($0.value)) }.joined(separator: " or ")
            + (roots.count > limit ? " … (\(roots.count) roots)" : "")
    }
    var display: String {
        get throws {
            if scope == .identity { return "All real " + variable }
            if roots.isEmpty { return scope == .bracketedRoots ? "No root found" : inDomain ? "No real solutions in the domain" : "No real solutions" }
            return try join({ try $0.with { $0.isApproximate = false }.display }, 6)
        }
    }
    var copyText: String { get throws { roots.isEmpty || scope == .identity ? try display : try join(EquationValue.full, EquationValue.maxRoots) } }
    var description: String { (try? display) ?? "" }
    static func == (a: EquationValue, b: EquationValue) -> Bool { a === b }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Cross-cancel before constructing a bounded fraction, avoiding oversized reducible intermediates.
enum EquationFraction {
    static func add(_ a: Rational, _ b: Rational) throws -> Rational {
        let g = BigInt.gcd(a.denominator, b.denominator)
        return try reduced(a.numerator * (b.denominator / g) + b.numerator * (a.denominator / g), (a.denominator / g) * b.denominator)
    }
    static func negate(_ a: Rational) -> Rational { -a }
    static func subtract(_ a: Rational, _ b: Rational) throws -> Rational { try add(a, negate(b)) }
    static func multiply(_ a: Rational, _ b: Rational) throws -> Rational {
        var g = BigInt.gcd(a.numerator, b.denominator), h = BigInt.gcd(b.numerator, a.denominator)
        if g.isZero { g = .one }
        if h.isZero { h = .one }
        return try Rational((a.numerator / g) * (b.numerator / h), (a.denominator / h) * (b.denominator / g))
    }
    static func divide(_ a: Rational, _ b: Rational) throws -> Rational { try multiply(a, try Rational(b.denominator, b.numerator)) }
    private static func reduced(_ n: BigInt, _ d: BigInt) throws -> Rational {
        let g = BigInt.gcd(n, d)
        return g.isZero ? try Rational(n, d) : try Rational(n / g, d / g)
    }
    static func compare(_ a: Rational, _ b: Rational) -> Int { BigInt.compare(a.numerator * b.denominator, b.numerator * a.denominator) }
    static func abs(_ a: Rational) -> Rational { a.abs }
    static func half(_ a: Rational) throws -> Rational { try divide(a, Rational(2)) }
}
