import Foundation

final class ResistorLiteralExpression: Expression { let bands: [String]; init(_ bands: [String]) { self.bands = bands } }

// `a || b` (parallel) lives with the core operator ladder in Expressions.swift.
extension ExpressionParser {
    /// Three to five colour words in a row (`brown black red gold`), unless the words name a variable or call a function.
    func tryResistorLiteral() throws -> Expression? {
        if knownNameLength(position) > 0 || position + 1 < tokens.count && tokens[position + 1].text == "(" { return nil }
        var cursor = position; var bands: [String] = []
        while cursor < tokens.count && tokens[cursor].kind == .name, let color = ResistorColorCatalog.tryGet(tokens[cursor].text) {
            if bands.count == 5 { throw CalcError.format("Resistor markings support at most five bands") }
            bands.append(color.name); cursor += 1
        }
        if bands.count < 3 { return nil }
        position = cursor; return ResistorLiteralExpression(bands)
    }
}
