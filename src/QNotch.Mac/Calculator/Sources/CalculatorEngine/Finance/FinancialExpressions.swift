import Foundation

/// `loan|mortgage|amortize|save … at … for …` and bare `amount at rate for term` (C# FinancialPlanExpression).
final class FinancialPlanExpression: Expression {
    let kind: String, amount: Expression, rate: Expression, term: Expression, downPayment: Expression?
    /// Compounding periods per year: 12 or 1.
    let frequency: Int
    var compoundingSpecified = false
    init(_ kind: String, _ amount: Expression, _ rate: Expression, _ term: Expression, _ downPayment: Expression? = nil, _ frequency: Int = 1) {
        self.kind = kind; self.amount = amount; self.rate = rate; self.term = term; self.downPayment = downPayment; self.frequency = frequency
    }
    var children: [Expression] { downPayment.map { [amount, rate, term, $0] } ?? [amount, rate, term] }
}

extension ExpressionParser {
    func tryFinancialSentence() throws -> Expression? {
        if tokens.count < 5 || knownNames?.contains(tokens.map(\.text).joined(separator: " ")) == true { return nil }
        var kind = tokens[0].text.netLower
        let prefixed = kind == "loan" || kind == "mortgage" || kind == "amortize" || kind == "save"
        if prefixed && (knownNameLength(0) > 0 || tokens[1].text == "(") { return nil }
        // The first top-level occurrence of `word` at or after `start`; brackets nest.
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
        let at = try find("at", 1)
        let duration = at < 0 ? -1 : try find("for", at + 1)
        if at < 0 || duration < 0 { return nil }
        func part(_ start: Int, _ end: Int) throws -> Expression {
            if end <= start { throw CalcError.format("Missing financial input") }
            return try sub(start, end - start).parse()
        }
        var frequency = 1, termEnd = tokens.count, amountEnd = at
        let compounded = try find("compounded", duration + 1)
        if compounded >= 0 {
            if prefixed && kind != "save" || compounded != tokens.count - 2 { throw CalcError.format("Expected compounded monthly or annually after the term") }
            switch tokens[tokens.count - 1].text.netLower {
            case "monthly": frequency = 12
            case "annually", "yearly": frequency = 1
            default: throw CalcError.format("Unsupported compounding frequency")
            }
            termEnd = compounded
        }
        if !prefixed { kind = "grow" }
        var down: Expression?
        let start = prefixed ? 1 : 0
        if kind == "mortgage" || kind == "loan" || kind == "amortize" {
            let with = try find("with", start)
            if with >= 0 && with < at {
                if !tokens[at - 1].text.equalsIgnoreCase("down") { throw CalcError.format("Expected down after the down payment") }
                down = try part(with + 1, at - 1); amountEnd = with
            }
        }
        if kind == "save" {
            let unit = tokens[at - 1].text.netLower
            let contributionFrequency: Int
            switch unit {
            case "monthly", "month": contributionFrequency = 12
            case "yearly", "annually", "year": contributionFrequency = 1
            default: throw CalcError.format("Savings require monthly or yearly contributions")
            }
            amountEnd = at - 1
            if unit == "month" || unit == "year" {
                let before = amountEnd > start ? tokens[amountEnd - 1].text.netLower : ""
                if amountEnd <= start || before != "/" && before != "per" { throw CalcError.format("Expected / or per before the contribution period") }
                amountEnd -= 1
            }
            if compounded >= 0 && frequency != contributionFrequency { throw CalcError.arithmetic("Contribution and compounding periods must match") }
            frequency = contributionFrequency
        }
        let expression = FinancialPlanExpression(kind, try part(start, amountEnd), try part(at + 1, duration), try part(duration + 1, termEnd), down, frequency)
        expression.compoundingSpecified = compounded >= 0
        return expression
    }
}
