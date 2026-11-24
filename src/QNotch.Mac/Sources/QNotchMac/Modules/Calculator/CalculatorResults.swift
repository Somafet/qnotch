import Foundation
import CalculatorEngine

/// How a sheet result reads beside its line, in its hover card and in its explanation (Windows
/// CalculatorSurface.Results and .Explanations). Pure functions of the engine's line result.
enum CalculatorResultText {
    /// What the result column shows.
    static func shown(_ line: CalculatorLineResult) -> String {
        if !line.answer.isEmpty { return line.answer }
        return line.error ?? line.pending ?? ""
    }

    /// Lines with something to show beside them.
    static func isShown(_ line: CalculatorLineResult) -> Bool { !line.isBlank && !shown(line).isEmpty }

    /// A value the user can copy (not an error, prose, declaration or unrolled dice line).
    static func copies(_ line: CalculatorLineResult) -> Bool { line.hasValue && line.error == nil && line.pending == nil }

    /// "Line 3: 387. Copy result" (1-based line numbers, as Windows).
    static func accessibilityName(_ line: CalculatorLineResult) -> String {
        copies(line) ? CalculatorText.resultNameCopy(line.line + 1, shown(line)) : CalculatorText.resultName(line.line + 1, shown(line))
    }

    /// The hover card's note and sources: "where did this come from?". The complete trace stays behind Explain.
    static func summary(_ line: CalculatorLineResult) -> (note: String, sources: String) {
        // "Exact …" and "Explicit …" describe the engine's guarantees, not this value's origin.
        let assumption = line.explanation.last { step in
            guard let text = step.assumption, step.operation != "reference" else { return false }
            return !text.hasPrefix("Exact ") && !text.hasPrefix("Explicit ")
        }?.assumption
        var note = assumption.map { $0.components(separatedBy: "; ").prefix(2).joined(separator: ", ") } ?? ""
        // A plot, chart or table says what it shows.
        if let figure = line.figure { note = figure.summary }
        let sources = line.dependencies.isEmpty ? "" : CalculatorText.uses(line.dependencies)
        return (note, sources)
    }

    enum Card: Equatable {
        case problem(String)
        /// `headline` is the exact held value when the row shows something else.
        case explain(headline: String?, note: String, sources: String, kind: String?)

        /// Plain text of everything the card shows, for accessibility and outlines.
        var text: String {
            switch self {
            case .problem(let message): message
            case let .explain(headline, note, sources, kind):
                [headline ?? "", note, [kind ?? "", sources].filter { !$0.isEmpty }.joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
    }

    /// The hover card, or nil when it would say nothing the row does not (Windows HoverCard).
    static func card(_ line: CalculatorLineResult) -> Card? {
        if let error = line.error { return .problem(error) }
        guard line.hasValue else { return nil }
        let (note, sources) = summary(line)
        // A rounded or compound row keeps its exact value one hover away.
        let headline = line.exact != shown(line) && !line.exact.isEmpty ? line.exact : nil
        guard headline != nil || !note.isEmpty || !sources.isEmpty else { return nil }
        return .explain(headline: headline, note: note, sources: sources, kind: kindName(line.kind))
    }

    /// "LocalTimestamp" reads "Local timestamp".
    static func kindName(_ kind: String?) -> String? {
        guard let kind, !kind.isEmpty else { return nil }
        var words: [String] = []
        var current = ""
        for character in kind {
            if character.isUppercase, !current.isEmpty { words.append(current); current = "" }
            current.append(character)
        }
        words.append(current)
        let text = words.enumerated().map { $0.offset == 0 ? $0.element : $0.element.lowercased() }.joined(separator: " ")
        return text
    }

    /// Whether the line has a calculation trace to explain.
    static func explains(_ line: CalculatorLineResult) -> Bool { line.hasValue && !explanation(line).isEmpty }

    /// The full trace (Windows Explain): every step as "operation(operands) = result", its evidence and
    /// assumption, then the lines it uses.
    static func explanation(_ line: CalculatorLineResult) -> String {
        var text: [String] = []
        for step in line.explanation {
            text.append("\(step.operation)(\(step.operands.joined(separator: ", "))) = \(step.result)")
            text += step.details
            if let assumption = step.assumption { text.append(assumption) }
        }
        if !line.dependencies.isEmpty { text.append(CalculatorText.uses(line.dependencies)) }
        return text.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
