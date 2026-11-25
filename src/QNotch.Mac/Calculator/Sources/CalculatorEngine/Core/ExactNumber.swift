import Foundation

/// An immutable exact real: a rational plus rational multiples of square-free integer roots (C# ExactNumber).
struct ExactNumber: Hashable, CustomStringConvertible {
    struct Term: Hashable { let radicand: BigInt; let coefficient: Rational }
    /// The rational part.
    let constant: Rational
    /// The radical terms in ascending radicand order; nil when rational.
    private let radicalTerms: [Term]?

    init(_ value: Rational) { constant = value; radicalTerms = nil }
    /// `default(ExactNumber)`: zero.
    static let zero = ExactNumber(Rational.zero)
    /// Terms keyed by radicand (1 holds the rational part); zero coefficients drop out.
    init(terms: [BigInt: Rational]) throws {
        constant = terms[.one] ?? .zero
        let radicals = terms.filter { !$0.key.isOne && !$0.value.isZero }.sorted { $0.key < $1.key }.map { Term(radicand: $0.key, coefficient: $0.value) }
        if radicals.count > 32 { throw CalcError.arithmetic("Radical term limit exceeded") }
        radicalTerms = radicals.isEmpty ? nil : radicals
    }
    var radicals: [Term] { radicalTerms ?? [] }
    var isRational: Bool { radicalTerms == nil }
    var isZero: Bool { isRational && constant.isZero }
    /// The rational value; throws when radicals remain.
    var rational: Rational { get throws { if isRational { return constant }; throw CalcError.arithmetic("Exact rational value required") } }
    /// The terms with the rational part first (when nonzero).
    var terms: [Term] { (constant.isZero ? [] : [Term(radicand: .one, coefficient: constant)]) + radicals }

    var description: String { (try? text()) ?? "" }
    /// ToString(); throws past 2048 characters as C# does.
    func text() throws -> String {
        if isRational { return constant.description }
        var text = ""
        for term in terms {
            let negative = term.coefficient.sign < 0
            text += text.isEmpty ? (negative ? "-" : "") : (negative ? " - " : " + ")
            let coefficient = term.coefficient.abs
            if term.radicand.isOne { text += coefficient.description }
            else {
                if coefficient != .one {
                    let value = coefficient.description
                    text += (value.contains("/") ? "(" + value + ")" : value) + "*"
                }
                text += "sqrt(" + term.radicand.description + ")"
            }
            if text.netLength > 2048 { throw CalcError.arithmetic("Output limit exceeded") }
        }
        return text
    }
}
