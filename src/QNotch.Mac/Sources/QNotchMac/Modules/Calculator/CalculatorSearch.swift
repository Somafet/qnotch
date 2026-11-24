import AppKit
import CalculatorEngine

/// Calculator answers in Search (Windows CalculatorSearch). `find` runs on the main thread on every keystroke,
/// so it only reads finished answers: a new expression is calculated off the main thread, the stale one is
/// cancelled, and Search is asked to look again when the answer is ready. The engine loads on the first query
/// that looks like a calculation.
final class CalculatorSearch {
    struct Answer: Equatable { let answer: String; let copy: String }

    private static let maxRemembered = 32
    private static let timeLimit: TimeInterval = 2
    private let queue = CalculatorThread(name: "qnotch.calculator.search")
    private var engine: CalculatorQuick?
    private var answers: [String: Answer?] = [:]
    private var order: [String] = []
    private var pending: CalculatorCancellation?
    private var latest: String?
    /// The saved functions, read only when the workspace is already open.
    var functions: () -> CalculatorFunctions? = { nil }
    /// The cached exchange rates, read only when the workspace has already read them.
    var rates: () -> CalculatorRates? = { nil }
    /// An answer arrived for the query Search is showing.
    var answered: (() -> Void)?
    /// Copies a chosen answer and closes the panel.
    var run: ((Answer) -> Void)?

    func find(_ query: String) -> [SearchHit] {
        guard CalculatorQuick.looksLikeCalculation(query) else {
            cancel()
            return []
        }
        if let known = answers[query] {
            if latest != query { cancel() }
            guard let known else { return [] }
            return [SearchHit(title: known.answer, detail: query, symbol: "equal.circle") { [weak self] in self?.run?(known) }]
        }
        if latest != query { calculate(query) }
        return []
    }

    /// Answers can depend on today's date and the saved functions.
    func forget() {
        cancel()
        answers.removeAll()
        order.removeAll()
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
        latest = nil
    }

    private func calculate(_ query: String) {
        cancel()
        let token = CalculatorCancellation()
        pending = token
        latest = query
        let functions = functions(), rates = rates()
        // Off the main thread: the first use of a code path can be slow, so a run that takes too long is no answer.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeLimit) { token.cancel() }
        queue.async { [weak self] in
            guard let self, !token.isCancelled else { return }
            if self.engine == nil {
                let engine = CalculatorQuick()
                _ = engine.answer("1 + 1") // pays the first-use cost here
                self.engine = engine
            }
            let format = CalculatorFormat(styleId: CalculatorPreferences.defaultNumberStyle)
            let result = self.engine?.answer(query, format: format, functions: functions, rates: rates, cancel: token)
            let timedOut = token.isCancelled
            DispatchQueue.main.async {
                guard self.pending === token, self.latest == query else { return }
                self.pending = nil
                self.latest = nil
                if timedOut { return } // ran out of time: not an answer to remember
                self.remember(query, result.map { Answer(answer: $0.answer, copy: $0.copy) })
                self.answered?()
            }
        }
    }

    private func remember(_ query: String, _ answer: Answer?) {
        if answers.updateValue(answer, forKey: query) == nil { order.append(query) }
        while order.count > Self.maxRemembered { answers[order.removeFirst()] = nil }
    }

    /// Whether a background calculation is running (smoke checks wait for it).
    var isCalculating: Bool { pending != nil }
}
