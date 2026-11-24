import Foundation

/// Plain-text rendering of a result's structured explanation (C# ExplanationText, which mirrors the Windows F1 text).
/// It formats the existing result and never computes a separate answer.
enum ExplanationText {
    /// The evidence lines a step carries after its "operation(operands) = result" line, in C# order (assumption included).
    static func stepLines(_ step: CalculationStep) -> [String] {
        var lines: [String] = []
        if let payroll = step.payroll { lines += PayrollBreakdownText.lines(payroll) }
        if let assumption = step.assumption { lines.append(assumption) }
        lines += evidenceLines(step)
        return lines
    }
    /// The evidence after the assumption: text transforms, chemistry composition and amortization rows.
    static func evidenceLines(_ step: CalculationStep) -> [String] {
        var lines: [String] = []
        if let transform = step.textTransform {
            lines.append("UTF-8 input: \(transform.inputUtf8Bytes) bytes; output: \(transform.outputUtf8Bytes) bytes")
            lines.append("Input preview: " + transform.inputPreview)
            lines.append("Input byte prefix (hex): " + transform.inputBytePreview)
        }
        if let chemistry = step.chemistry {
            lines.append("Formula \(chemistry.formula): \(chemistry.nominalGramsPerMole) g/mol nominal")
            for element in chemistry.composition {
                lines.append("\(element.symbol) × \(element.atoms): \(element.atomicWeight) ± \(element.quotedUncertainty) quoted atomic weight; contribution \(element.gramsPerMole) g/mol")
            }
            lines.append(chemistry.source)
        }
        for year in step.schedule ?? [] {
            lines.append("Year \(year.year) (\(year.payments) payments): interest \(year.interest), principal \(year.principal), balance \(year.balance)")
        }
        return lines
    }
    /// What the answer's value adds below its steps (integer words, text, rates, networks, colours, …), and its dependencies.
    static func valueLines(_ answer: LineResult) throws -> [String] {
        var lines: [String] = []
        func appendDetail(_ detail: String) { if !answer.explanation.contains(where: { $0.assumption?.contains(detail) == true }) { lines.append(detail) } }
        switch answer.value {
        case .integer(let word)?:
            lines.append(word.width.map { "\($0)-bit \(word.signed ? "signed" : "unsigned"); base \(word.radix)" } ?? "Exact integer; base \(word.radix)")
            lines.append("Decimal value: " + word.value.description)
            lines.append("Full representation: " + word.fullText)
            lines.append("Reusable expression: " + (try word.copyText))
        case .text(let text)?:
            lines.append("Complete text expression: " + text.expressionText)
            if text.copiesExpression { lines.append("Contains NUL; clipboard uses the escaped expression to retain all text") }
        case .usageCount(let count)?: appendDetail(try count.details)
        case .usagePrice(let price)?: appendDetail(try price.details)
        case .uptimeBudget(let uptime)?: appendDetail(try uptime.details)
        case .network(let network)?: lines.append(network.details)
        case .colour(let colour)?: lines.append(try colour.details)
        case .permission(let permission)?: lines.append(permission.details)
        case .aspect(let aspect)?: lines.append(aspect.details)
        case .unicode(let unicode)?: lines.append(unicode.details)
        case .equation(let equation)?: lines.append(equation.details)
        case .plot(let plot)?: lines.append(plot.details)
        case .chart(let chart)?: lines.append(chart.details)
        case .table(let table)?: lines.append(table.details)
        default: break
        }
        if !answer.dependencies.isEmpty { lines.append("Uses " + answer.dependencies.prefix(16).map { "L\($0 + 1)" }.joined(separator: ", ")) }
        return lines
    }
    static func render(_ answer: LineResult) throws -> String {
        var lines: [String] = []
        for step in answer.explanation {
            lines.append(step.operation + "(" + step.operands.joined(separator: ", ") + ") = " + step.result)
            lines += stepLines(step)
        }
        lines += try valueLines(answer)
        return (lines.map { $0 + "\n" }.joined()).netTrimEnd
    }
}
