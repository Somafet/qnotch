import Foundation

/// Immutable complex number with a nonzero imaginary part. A zero imaginary part is always a real number instead.
struct ComplexValue: Hashable, CustomStringConvertible {
    private static let maxOutput = 2048
    let real: ExactNumber
    let imaginary: ExactNumber
    let isApproximate: Bool
    init(_ real: ExactNumber, _ imaginary: ExactNumber, _ isApproximate: Bool = false) throws {
        if imaginary.isZero { throw CalcError.arithmetic("A complex value requires a nonzero imaginary part") }
        self.real = real; self.imaginary = imaginary; self.isApproximate = isApproximate
    }
    var display: String { get throws { (isApproximate ? "≈ " : "") + (try text(isApproximate)) } }
    /// Complete parts without the marker or display rounding; pasting it back reproduces the value.
    var copyText: String { get throws { try text(false) } }
    private func text(_ rounded: Bool) throws -> String {
        let math = ExactArithmetic(ExecutionBudget(), .none)
        func part(_ value: ExactNumber) throws -> String { rounded ? (try FormulaNumbers.fromDouble(FormulaNumbers.toDouble(value))).description : try value.text() }
        let negative = try math.sign(imaginary) < 0
        let size = try part(negative ? try math.negate(imaginary) : imaginary)
        let imaginaryText: String
        if size == "1" { imaginaryText = "i" }
        else if size.utf16.allSatisfy({ NetChar.isAsciiDigit($0) || $0 == 0x2E }) { imaginaryText = size + "i" }
        else if size.netContains(" ") || size.netContains("/") && !size.contains("sqrt") { imaginaryText = "(" + size + ")*i" }
        else { imaginaryText = size + "*i" }
        let text = real.isZero ? (negative ? "-" : "") + imaginaryText : (try part(real)) + (negative ? " - " : " + ") + imaginaryText
        if text.netLength > ComplexValue.maxOutput { throw CalcError.arithmetic("Output limit exceeded") }
        return text
    }
    var description: String { (try? display) ?? "" }
}
