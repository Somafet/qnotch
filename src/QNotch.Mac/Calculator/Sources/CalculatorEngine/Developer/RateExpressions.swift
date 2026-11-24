import Foundation

// The usage expression nodes and the RateSyntax/usage-suffix parser pieces of C# RateExpressions.cs live in the core
// (Expressions.swift, ExpressionParser+Core.swift); this file holds the rest.

extension ExpressionParser {
    /// "rate for duration" and "target uptime for interval" sentences (C# TryRateForSentence).
    func tryRateForSentence() throws -> Expression? {
        if tokens.count < 3 || knownNames?.contains(tokens.map(\.text).joined(separator: " ")) == true { return nil }
        var nesting = 0, split = -1, uptime = -1
        for (i, token) in tokens.enumerated() {
            try cancellationToken.throwIfCancellationRequested(); let text = token.text
            if text == "(" || text == "[" { nesting += 1 } else if text == ")" || text == "]" { nesting -= 1 }
            else if nesting == 0 && text.equalsIgnoreCase("for") { split = i; break }
            else if nesting == 0 && text.equalsIgnoreCase("uptime") { uptime = i }
        }
        if split < 1 || split == tokens.count - 1 { return nil }
        func part(_ start: Int, _ end: Int) throws -> Expression { try sub(start, end - start).parse() }
        if uptime > 0 && uptime == split - 1 { return CallExpression("downtime", [try part(0, uptime), try part(split + 1, tokens.count)]) }
        return RateForExpression(try part(0, split), try part(split + 1, tokens.count))
    }
}
