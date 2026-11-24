import Foundation

// EarningsExpressions.cs. The earnings suffix/target parsing (EarningsAttachExpression, EarningsConvertExpression,
// earningsTarget, tryCalendarEarningsSuffix) is part of the shared parser spine in Core/.

/// `issue net days`: an invoice due date.
final class InvoiceDueExpression: Expression {
    let date: Expression, days: Expression
    init(_ date: Expression, _ days: Expression) { self.date = date; self.days = days }
    var children: [Expression] { [date, days] }
}
/// `late fee principal at rate/day for duration`.
final class LateFeeExpression: Expression {
    let principal: Expression, rate: Expression, duration: Expression
    init(_ principal: Expression, _ rate: Expression, _ duration: Expression) { self.principal = principal; self.rate = rate; self.duration = duration }
    var children: [Expression] { [principal, rate, duration] }
}

extension ExpressionParser {
    func tryInvoiceSentence() throws -> Expression? {
        if tokens.count < 3 || knownNames?.contains(tokens.map(\.text).joined(separator: " ")) == true { return nil }
        // No empty-part check here (unlike the planning sentences): an empty part fails in its own parser.
        func part(_ start: Int, _ end: Int) throws -> Expression { try sub(start, end - start).parse() }
        func find(_ word: String, _ start: Int) throws -> Int {
            var nesting = 0
            for i in 0..<tokens.count {
                try cancellationToken.throwIfCancellationRequested()
                let text = tokens[i].text
                if text == "(" || text == "[" { nesting += 1 }
                else if text == ")" || text == "]" { nesting -= 1 }
                else if i >= start && nesting == 0 && text.equalsIgnoreCase(word) { return i }
            }
            return -1
        }
        if tokens[0].text.equalsIgnoreCase("late") && tokens[1].text.equalsIgnoreCase("fee") && knownNameLength(0) == 0 {
            let at = try find("at", 2); let forIndex = at < 0 ? -1 : try find("for", at + 1)
            if at < 3 || forIndex < at + 4 || forIndex >= tokens.count - 1 || !["day", "days"].contains(tokens[forIndex - 1].text.netLower) ||
                !["/", "per"].contains(tokens[forIndex - 2].text.netLower) {
                throw CalcError.format("Expected late fee amount at rate/day for duration")
            }
            return LateFeeExpression(try part(2, at), try part(at + 1, forIndex - 2), try part(forIndex + 1, tokens.count))
        }
        let net = try find("net", 1)
        if net < 1 || net >= tokens.count - 1 || ["in", "gross"].contains(tokens[net + 1].text.netLower) { return nil }
        return InvoiceDueExpression(try part(0, net), try part(net + 1, tokens.count))
    }
}
