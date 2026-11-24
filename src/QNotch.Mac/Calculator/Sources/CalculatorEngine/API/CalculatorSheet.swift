import Foundation

// The engine's public surface for the Mac app. The engine's own types stay internal; the app sees these
// small value types, so the port can follow the C# structure without exposing it.

/// One explanation step of a line (C# CalculationStep).
public struct CalculatorStep: Hashable, Sendable {
    public let operation: String
    public let operands: [String]
    public let result: String
    public let assumption: String?
    /// Extra evidence lines the step carries (payroll breakdowns, chemistry composition, schedules…).
    public let details: [String]
}

/// One evaluated sheet line, as the app presents it.
public struct CalculatorLineResult: Hashable, Sendable {
    /// Zero-based line index.
    public let line: Int
    /// What the result column shows (formatted with the sheet's number style and decimals).
    public let answer: String
    /// What copying the result puts on the clipboard.
    public let copy: String
    /// The canonical, exact display (C# LineResult.Display), for the hover card.
    public let exact: String
    public let error: String?
    /// An unrolled dice line's muted range.
    public let pending: String?
    public let isDeclaration: Bool
    public let isAggregate: Bool
    /// True when the line has a value (not an error, prose or declaration).
    public let hasValue: Bool
    /// The value's kind name (C# SheetValueKind), e.g. "Number", "Money", "Date".
    public let kind: String?
    public let explanation: [CalculatorStep]
    /// Zero-based lines this line reads.
    public let dependencies: [Int]
    /// True for an empty, heading or prose line: nothing to show.
    public var isBlank: Bool { answer.isEmpty && error == nil && pending == nil }
}

/// Display preferences for results (C# ResultFormat): number style id ("plain", "system", "comma", "period",
/// "space", "apostrophe") and fixed decimal places (nil = automatic).
public struct CalculatorFormat: Hashable, Sendable {
    public var styleId: String?
    public var decimalPlaces: Int?
    public var locale: Locale
    public init(styleId: String? = nil, decimalPlaces: Int? = nil, locale: Locale = .current) {
        self.styleId = styleId; self.decimalPlaces = decimalPlaces; self.locale = locale
    }
    public static let maxDecimalPlaces = ResultFormat.maxDecimalPlaces
    public static let styleIds = NumberStyle.presetIds
    /// "1,234.56" for a style id under this locale.
    public func example(_ styleId: String) -> String { (try? NumberStyle.fromId(styleId, RegionalNumberFormat(locale)))?.example ?? "" }
    var resultFormat: ResultFormat {
        ResultFormat(decimalPlaces, (try? NumberStyle.fromId(styleId, RegionalNumberFormat(locale))) ?? .plain)
    }
}

/// The host snapshot a sheet evaluates under (C# EvaluationContext). `now` and `today` are captured once per evaluation.
public struct CalculatorEnvironment: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    /// Two-letter region for working-day calendars and payroll defaults (e.g. "US", "GB", "RO").
    public var region: String?
    /// Currency plain monetary results are shown in (display only).
    public var displayCurrency: String?
    public init(now: Date = Date(), timeZone: TimeZone = .current, region: String? = Locale.current.region?.identifier, displayCurrency: String? = nil) {
        self.now = now; self.timeZone = timeZone; self.region = region; self.displayCurrency = displayCurrency
    }
    func context(rates: CurrencyRateBook?) -> EvaluationContext {
        // Whole seconds, like the Windows host, so a sheet does not change within one second.
        let unixTicks = Int64((now.timeIntervalSince1970).rounded(.down)) * Ticks.perSecond
        let instant = Instant(unixTicks: unixTicks)
        let offset = Int64(timeZone.secondsFromGMT(for: now))
        let localDay = Int((unixTicks + Ticks.unixEpoch + offset * Ticks.perSecond) / Ticks.perDay)
        var context = EvaluationContext(today: DateOnly(dayNumber: localDay), now: instant, localZone: CalculatorZones.local(timeZone), workdayRegion: region, currencyRates: rates)
        context.payrollRegion = region
        context.displayCurrency = displayCurrency
        return context
    }
}

/// The outcome of evaluating a whole sheet.
public struct CalculatorEvaluation: Sendable {
    public let lines: [CalculatorLineResult]
    /// The line results depend on today's date / the current instant / currency rates: re-evaluate when those change.
    public let usesCurrentDate: Bool
    public let usesCurrentInstant: Bool
    public let requiresSecondRefresh: Bool
    public let usesCurrencyRates: Bool
    public let hasMoney: Bool
    /// Lines an untagged whole-sheet total reads.
    public let totalMembers: [Int]
}

/// A sheet's evaluation session (C# SheetEvaluationSession): re-evaluating an edited sheet reuses unchanged lines.
/// Safe to call from any thread; calls are serialized.
public final class CalculatorSheet: @unchecked Sendable {
    private let session = SheetEvaluationSession()
    public init() {}

    /// Evaluates `source`. Throws only for whole-sheet limits (over 200,000 characters or 10,000 lines) and cancellation.
    public func evaluate(_ source: String, environment: CalculatorEnvironment = CalculatorEnvironment(), format: CalculatorFormat = CalculatorFormat(),
                         functions: CalculatorFunctions? = nil, rates: CalculatorRates? = nil, cancel: CalculatorCancellation? = nil) throws -> CalculatorEvaluation {
        let library = functions?.library ?? .empty
        let evaluation = try session.evaluateWithFunctions(source, library, functions?.receipts ?? [], cancel?.token ?? .none, context: environment.context(rates: rates?.book))
        let resultFormat = format.resultFormat
        return CalculatorEvaluation(lines: evaluation.results.map { CalculatorPresentation.line($0, resultFormat) },
                                    usesCurrentDate: evaluation.usesCurrentDate, usesCurrentInstant: evaluation.usesCurrentInstant,
                                    requiresSecondRefresh: evaluation.requiresSecondRefresh, usesCurrencyRates: evaluation.usesCurrencyRates,
                                    hasMoney: evaluation.hasMoney, totalMembers: evaluation.totalMembers)
    }

    /// Sheet limits (C# SheetEvaluator).
    public static let maxCharacters = SheetEvaluator.maxCharacters
    public static let maxLines = SheetEvaluator.maxLines
}

/// Cancels a running evaluation.
public final class CalculatorCancellation: @unchecked Sendable {
    let token = CancellationToken()
    public init() {}
    public func cancel() { token.cancel() }
    public var isCancelled: Bool { token.isCancellationRequested }
}

/// The saved user functions (C# FunctionLibrary plus the sheet's receipts).
public final class CalculatorFunctions: @unchecked Sendable {
    let library: FunctionLibrary
    let receipts: [FunctionReceipt]
    init(_ library: FunctionLibrary, _ receipts: [FunctionReceipt]) { self.library = library; self.receipts = receipts }
    public static let empty = CalculatorFunctions(.empty, [])
}

/// Cached exchange rates for money conversion (C# CurrencyRateBook).
public final class CalculatorRates: @unchecked Sendable {
    let book: CurrencyRateBook
    init(_ book: CurrencyRateBook) { self.book = book }
    public static let none = CalculatorRates(.empty)
}

/// How a result reads in the panel and in Search (Windows SheetDisplay), plus the conversion to public values.
enum CalculatorPresentation {
    /// The engine keeps repeating values as exact fractions. With automatic decimals a notepad answer reads better as a marked,
    /// rounded decimal, and copying gives what is on screen. A duration reads as days, hours and minutes. The exact value stays in
    /// the line's hover card and explanation. An explicit decimal places setting is followed as it is.
    static func present(_ result: LineResult, _ held: SheetValue, _ format: ResultFormat) throws -> (answer: String, copy: String) {
        let value = result.shown ?? held
        let exact = try ResultFormatter.format(result, format)
        guard format.decimalPlaces == nil, case .number(let number) = value, !number.useCompoundDuration, exact.contains("/") else { return (exact, try value.copyText) }
        if number.isDuration {
            let compound = try number.with { $0.useCompoundDuration = true; $0.useDaysInDuration = true }.display
            if !compound.contains("/") { return (compound, compound) } // 19/6 day reads as 3 day 4 h
        }
        var places = 4
        var rounded = try ResultFormatter.format(result, format.with(places: places))
        if !rounded.contains(where: { $0 >= "1" && $0 <= "9" }) {
            places = 10
            rounded = try ResultFormatter.format(result, format.with(places: places))
        }
        if rounded.contains("/") { return (exact, try value.copyText) }
        let copy = try number.with { $0.displayDecimalPlaces = places }.display.netTrimStart("≈", " ")
        return (rounded.hasPrefix("≈") ? rounded : "≈ " + rounded, copy)
    }
    static func line(_ result: LineResult, _ format: ResultFormat) -> CalculatorLineResult {
        var answer = result.display, copy = result.display
        if let value = result.value, !result.isDeclaration, result.error == nil, let presented = try? present(result, value, format) {
            answer = presented.answer; copy = presented.copy
        }
        return CalculatorLineResult(line: result.line, answer: answer, copy: copy, exact: result.display, error: result.error, pending: result.pending,
                                    isDeclaration: result.isDeclaration, isAggregate: result.isAggregate, hasValue: result.value != nil && !result.isDeclaration,
                                    kind: result.value?.kind.rawValue, explanation: result.explanation.map(step), dependencies: result.dependencies)
    }
    static func step(_ step: CalculationStep) -> CalculatorStep {
        CalculatorStep(operation: step.operation, operands: step.operands, result: step.result, assumption: step.assumption, details: StepDetails.lines(step))
    }
}

extension ResultFormat {
    func with(places: Int?) -> ResultFormat { var copy = self; copy.decimalPlaces = places; return copy }
}

/// Evidence lines a step carries beyond its assumption (filled in as the areas that produce evidence are ported).
enum StepDetails {
    static func lines(_ step: CalculationStep) -> [String] { [] }
}

/// The host's local zone as engine rules.
enum CalculatorZones {
    /// The embedded TZDB rules for the host zone's IANA id (C# LocalZoneSnapshot.FromTimeZoneInfo). Nil until the
    /// time-zone rules are available; "local" then reports that the local zone is unavailable.
    static func local(_ zone: TimeZone) -> LocalZoneSnapshot? { nil }
}
