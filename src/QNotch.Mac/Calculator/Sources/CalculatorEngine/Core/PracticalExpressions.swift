import Foundation

final class ChemistryExpression: Expression {
    let formula: String, amount: Expression?, target: UnitExpression?
    init(_ formula: String, _ amount: Expression? = nil, _ target: UnitExpression? = nil) { self.formula = formula; self.amount = amount; self.target = target }
    var children: [Expression] { amount.map { [$0] } ?? [] }
}
final class GradesExpression: Expression {
    let scores: [Expression], weights: [Expression]
    init(_ scores: [Expression], _ weights: [Expression]) { self.scores = scores; self.weights = weights }
    var children: [Expression] { scores + weights }
}
// EngineeringExpression (`x in eng`) is declared with the core nodes in Expressions.swift.

extension ExpressionParser {
    /// The tokens of one formula literal, glued back together: adjacent (joined) name, number and bracket tokens, or tokens around `·`.
    func chemicalFormula() throws -> String {
        let start = position; var nesting = 0, length = 0
        while position < tokens.count {
            let token = tokens[position], text = token.text
            if position > start && !token.joinedToPrevious && text != "·" && tokens[position - 1].text != "·" { break }
            if text == ")" && nesting == 0 || [",", "+", "-", "*", "/", "^", "%", "!"].contains(text) { break }
            if token.kind != .name && token.kind != .number && !["(", ")", "[", "]", "·"].contains(text) { break }
            if text == "(" || text == "[" { nesting += 1 }
            if text == ")" || text == "]" { nesting -= 1 }
            length += text.netLength; if length > 512 { throw CalcError.arithmetic("Chemical formula exceeds 512 characters") }
            position += 1
        }
        if position == start { throw CalcError.format("Expected a chemical formula literal") }
        return tokens[start..<position].map(\.text).joined()
    }
    /// `molar mass H2O`, `molarMass(H2O)`, `moles(10 g, H2O)` and `massOf(2 mol, NaCl)`.
    func tryChemistryAtom() throws -> Expression? {
        let key = current.text.netLower
        let chemical = key == "molarmass" || key == "moles" || key == "massof"
        let chemicalCall = chemical && position + 1 < tokens.count && tokens[position + 1].text == "("
        if knownNameLength(position) > 0 && !chemicalCall { return nil }
        if current.text.equalsIgnoreCase("molar") && position + 1 < tokens.count && tokens[position + 1].text.equalsIgnoreCase("mass") {
            position += 2; return ChemistryExpression(try chemicalFormula())
        }
        if !chemicalCall { return nil }
        position += 2
        let expression: Expression
        if key == "molarmass" { expression = ChemistryExpression(try chemicalFormula()) }
        else {
            let input = try rounded(); if !take(",") { throw CalcError.format("Chemical conversion expects quantity, formula literal") }
            let formula = try chemicalFormula()
            expression = ChemistryExpression(formula, input, try .single(UnitCatalog.byId(key == "moles" ? "mol" : "g")))
        }
        if !take(")") { throw CalcError.format("Expected ) after chemical formula") }
        return expression
    }
    /// `10 g H2O in mol`: a formula between a quantity and a mass or amount-of-substance target.
    func tryChemistrySuffix(_ expression: inout Expression) throws -> Bool {
        let grouped = current.text == "(" || current.text == "["
        if !grouped {
            guard current.kind == .name, let first = current.text.utf16.first, first >= 0x41 && first <= 0x5A, knownNameLength(position) == 0 else { return false }
        }
        if expression is LiteralExpression || expression is ScaleExpression { return false }
        if !grouped, !(expression is UnitExpressionNode), try UnitCatalog.tryToken(current.text) != nil { return false }
        let saved = position; let formula = try chemicalFormula()
        guard take("in") || takeKeyword(.to), let target = try UnitParser.tryParse(tokens, &position, nil) else { position = saved; return false }
        if target.dimension != Dimension(0, 1, 0, 0, 0, 0, 0, 0) && target.dimension != Dimension(0, 0, 0, 0, 0, 1, 0, 0) { position = saved; return false }
        expression = ChemistryExpression(formula, expression, target); return true
    }
    /// `grades 9 x3, 7 x2`: score/weight pairs separated by `x` (or `x3` written as one word).
    func tryGrades() throws -> Expression? {
        if !current.text.equalsIgnoreCase("grades") || knownNameLength(position) > 0 { return nil }
        position += 1; var scores: [Expression] = [], weights: [Expression] = []
        func isOpen(_ text: String) -> Bool { text == "(" || text == "[" }
        func isClose(_ text: String) -> Bool { text == ")" || text == "]" }
        while position < tokens.count {
            if scores.count == 128 { throw CalcError.arithmetic("Grades exceed 128 natural-language pairs; use weightedMean lists") }
            var end = position, nesting = 0
            while end < tokens.count {
                if nesting == 0 && tokens[end].text == "," { break }
                if isOpen(tokens[end].text) { nesting += 1 }
                if isClose(tokens[end].text) { nesting -= 1 }
                end += 1
            }
            var separator = -1; nesting = 0
            for i in position..<end {
                let token = tokens[i], u = token.text.units
                let joinedWeight = token.kind == .name && u.count > 1 && (u[0] == 0x78 || u[0] == 0x58) && u.dropFirst().allSatisfy(NetChar.isAsciiDigit)
                if nesting == 0 && (token.text.equalsIgnoreCase("x") || joinedWeight) { separator = i; break }
                if isOpen(token.text) { nesting += 1 }
                if isClose(token.text) { nesting -= 1 }
            }
            if separator <= position { throw CalcError.format("Grades require score x weight pairs") }
            func part(_ input: [Token]) throws -> Expression { try ExpressionParser(input, cancellationToken, knownNames, questionDepth + 1).parse() }
            scores.append(try part(Array(tokens[position..<separator])))
            var tail = Array(tokens[(separator + 1)..<end])
            if tokens[separator].text.netLength > 1 { tail.insert(Token(.number, tokens[separator].text.netSubstring(1)), at: 0) }
            weights.append(try part(tail)); position = end
            if !take(",") { break }
        }
        return GradesExpression(scores, weights)
    }
}
