import Foundation

/// `fire …` and `depreciate …` sentences (C# PlanningSentenceExpression). `annualScale` turns monthly FIRE
/// spending into annual spending; `period` names the source period for the explanation.
final class PlanningSentenceExpression: Expression {
    let name: String, arguments: [Expression], annualScale: Int, period: String
    init(_ name: String, _ arguments: [Expression], annualScale: Int = 1, period: String = "") {
        self.name = name; self.arguments = arguments; self.annualScale = annualScale; self.period = period
    }
    var children: [Expression] { arguments }
}

extension ExpressionParser {
    func tryPlanningSentence() throws -> Expression? {
        if tokens.count < 3 || knownNames?.contains(tokens.map(\.text).joined(separator: " ")) == true { return nil }
        func part(_ start: Int, _ end: Int) throws -> Expression {
            if end <= start { throw CalcError.format("Missing financial planning input") }
            return try sub(start, end - start).parse()
        }
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
        let first = tokens[0].text.netLower
        if (first == "fire" || first == "depreciate" || first == "break") && (knownNameLength(0) > 0 || tokens[1].text == "(") { return nil }
        if first == "fire" {
            let at = try find("at", 1); let end = at < 0 ? tokens.count : at
            let period = tokens[end - 1].text.netLower
            let scale: Int
            switch period {
            case "month", "monthly": scale = 12
            case "year", "yearly", "annually": scale = 1
            default: throw CalcError.format("FIRE spending requires a monthly or yearly period")
            }
            var amountEnd = end - 1
            if period == "month" || period == "year" {
                if amountEnd <= 1 || tokens[amountEnd - 1].text.netLower != "/" && tokens[amountEnd - 1].text.netLower != "per" {
                    throw CalcError.format("Expected / or per before the spending period")
                }
                amountEnd -= 1
            }
            var args = [try part(1, amountEnd)]
            if at >= 0 { args.append(try part(at + 1, tokens.count)) }
            return PlanningSentenceExpression("fire", args, annualScale: scale, period: scale == 12 ? "month" : "year")
        }
        if first == "depreciate" {
            let over = try find("over", 1)
            if over < 0 { throw CalcError.format("Expected over before useful life") }
            let salvage = try find("salvage", over + 1); let end = salvage < 0 ? tokens.count : salvage
            let period = tokens[end - 1].text.netLower
            if !["year", "years", "month", "months"].contains(period) { throw CalcError.format("Depreciation life requires months or years") }
            return PlanningSentenceExpression("sln", [try part(1, over), salvage < 0 ? LiteralExpression(.zero) : try part(salvage + 1, tokens.count), try part(over + 1, end - 1)],
                                              period: period.hasPrefix("month") ? "month" : "year")
        }
        if first == "break" && tokens[1].text.equalsIgnoreCase("even") {
            if !tokens[2].text.equalsIgnoreCase("fixed") { throw CalcError.format("Expected fixed cost") }
            let price = try find(",", 3); let cost = price < 0 ? -1 : try find(",", price + 1)
            if price < 0 || cost < 0 || price + 1 >= tokens.count || cost + 1 >= tokens.count || !tokens[price + 1].text.equalsIgnoreCase("price") || !tokens[cost + 1].text.equalsIgnoreCase("cost") {
                throw CalcError.format("Expected break even fixed amount, price amount, cost amount")
            }
            return CallExpression("breakeven", [try part(3, price), try part(price + 2, cost), try part(cost + 2, tokens.count)])
        }
        if tokens[tokens.count - 1].text.equalsIgnoreCase("inflation") {
            var minus = try find("minus", 1)
            if minus < 0 { minus = try find("-", 1) }
            if minus < 0 { return nil }
            return CallExpression("realreturn", [try part(0, minus), try part(minus + 1, tokens.count - 1)])
        }
        return nil
    }
}
