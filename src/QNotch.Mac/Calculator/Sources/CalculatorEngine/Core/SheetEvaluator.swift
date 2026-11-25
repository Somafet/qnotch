import Foundation

struct EvaluationStatistics: Equatable { let parsedLines: Int, evaluatedLines: Int, reusedResults: Int }

final class SheetEvaluation {
    let results: [LineResult]
    let functions: FunctionUpdate
    var uuidRequests: [UuidRequest] = []
    var usesCurrentDate = false
    var usesCurrentInstant = false
    var usesLocalTimeZone = false
    var requiresSecondRefresh = false
    var usesCurrencyRates = false
    var hasMoney = false
    var currencyRequests: [CurrencyRateRequest] = []
    /// Lines an untagged sheet-wide aggregate would read, in source order (block boundaries ignored).
    var totalMembers: [Int] = []
    init(_ results: [LineResult], _ functions: FunctionUpdate) { self.results = results; self.functions = functions }
}

/// One current-sheet snapshot. Cancellation cannot commit a partial cache.
final class SheetEvaluationSession {
    private let gate = NSLock()
    private let cache = EvaluationCache()
    private(set) var lastStatistics = EvaluationStatistics(parsedLines: 0, evaluatedLines: 0, reusedResults: 0)
    init() {}
    func evaluate(_ source: String, _ cancellationToken: CancellationToken = .none, context: EvaluationContext? = nil) throws -> [LineResult] {
        try evaluateWithFunctions(source, .empty, [], cancellationToken, context: context).results
    }
    func evaluateWithFunctions(_ source: String, _ library: FunctionLibrary, _ receipts: [FunctionReceipt], _ cancellationToken: CancellationToken = .none, context: EvaluationContext? = nil) throws -> SheetEvaluation {
        gate.lock(); defer { gate.unlock() }
        try cancellationToken.throwIfCancellationRequested()
        let result = try SheetEvaluator.evaluateFunctions(source, library, receipts, cancellationToken, cache, context)
        lastStatistics = cache.statistics
        return result
    }
}

final class EvaluationCache {
    var sources: [String] = []
    var scanned: [ParsedLine] = []
    var parsed: [ParsedLine] = []
    var names = NetHashSet<String>.ignoringCase()
    var results: [LineResult] = []
    var references: [NetDictionary<String, Int>] = []
    var aggregateReferences: [[Int]] = []
    var statistics = EvaluationStatistics(parsedLines: 0, evaluatedLines: 0, reusedResults: 0)
    var uuids: StableUuidContext?
    var uuidPending: [Bool] = []
    var functionKey = ""
    var today: DateOnly?
    var now: Instant?
    var zoneVersion: String?
    var localZoneVersion: String?
    var workdayRegion: String?
    var payrollRegion: String?
    var displayCurrency: String?
    var customHolidays: HolidaySet?
    var currencyRateKey = ""
    var currencyDate: DateOnly?
    var currencyRequests: [[DateOnlyKey]] = []
    var contextDependencies: [ContextDependency] = []
}

/// Deterministic typed sheet evaluation with explicit dependencies and no UI/network access.
enum SheetEvaluator {
    static let maxCharacters = 200_000
    static let maxLines = 10_000
    static let maxDependencyEdges = 100_000
    static let maxSheetSteps = 500_000

    /// `source.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n')`.
    static func splitLines(_ source: String) -> [String] {
        source.netReplace("\r\n", "\n").netReplace("\r", "\n").netSplit("\n")
    }
    static func evaluate(_ source: String, _ cancellationToken: CancellationToken = .none, context: EvaluationContext? = nil) throws -> [LineResult] {
        try evaluateFunctions(source, .empty, [], cancellationToken, nil, context).results
    }
    static func evaluateCached(_ source: String, _ cancellationToken: CancellationToken, _ cache: EvaluationCache?) throws -> [LineResult] {
        try evaluateFunctions(source, .empty, [], cancellationToken, cache).results
    }

    static func evaluateFunctions(_ source: String, _ library: FunctionLibrary, _ receipts: [FunctionReceipt], _ cancellationToken: CancellationToken, _ cache: EvaluationCache?, _ context: EvaluationContext? = nil) throws -> SheetEvaluation {
        let context = context ?? EvaluationContext()
        if source.netLength > maxCharacters { throw CalcError.argument("Sheet exceeds 200,000 characters") }
        let sourceLines = splitLines(source)
        if sourceLines.count > maxLines { throw CalcError.argument("Sheet exceeds 10,000 lines") }
        let tables = try TableSyntax.layout(sourceLines, cancellationToken)
        let count = sourceLines.count
        var parsed = [ParsedLine](); parsed.reserveCapacity(count)
        var scanned = [ParsedLine](); scanned.reserveCapacity(count)
        var parsedCount = 0, evaluatedCount = 0, reusedCount = 0
        func unchanged(_ i: Int) -> Bool { cache != nil && i < cache!.sources.count && cache!.sources[i] == tables.keys[i] }
        var assignments = NetDictionary<String, [Int]>.ignoringCase()
        for i in 0..<count {
            try cancellationToken.throwIfCancellationRequested()
            let line = unchanged(i) ? cache!.scanned[i] : try tables.scan(i, sourceLines, cancellationToken) ?? SheetSyntax.scan(sourceLines[i], cancellationToken)
            scanned.append(line); parsed.append(line)
            if let name = line.assignment { assignments.set(name, (assignments[name] ?? []) + [i]) }
        }
        let names = NetHashSet.ignoringCase(assignments.keys)
        // A user variable keeps its name; the automatic table of that name is then reachable only through its line.
        for table in tables.blocks where table.automatic {
            if var named = assignments[table.name], named.count > 1, let index = named.firstIndex(of: table.start) { named.remove(at: index); assignments.set(table.name, named) }
        }
        let functions = try FunctionUpdate.prepare(source, scanned, library, receipts, cancellationToken)
        let functionKey = functions.cacheKey
        let sameNames = cache != nil && cache!.names.setEquals(names)
        for i in 0..<count {
            if sameNames && unchanged(i) { parsed[i] = cache!.parsed[i] }
            else { parsed[i] = try SheetSyntax.parse(parsed[i], names, cancellationToken); parsedCount += 1 }
        }
        let syntax = parsed
        for i in 0..<count { if let error = functions.errors[i] { parsed[i].error = error } }
        var blockMembers = [[Int]](repeating: [], count: count)
        var memberLists: [[Int]] = [[]]; var current = 0
        var memberIndex = [Int](repeating: 0, count: count)
        var tags = NetDictionary<String, [Int]>.ignoringCase()
        var totalMembers: [Int] = []
        for i in 0..<count {
            if parsed[i].boundary { memberLists.append([]); current = memberLists.count - 1 }
            memberIndex[i] = current
            let line = parsed[i]
            if line.directive != nil || line.functionName != nil || line.assignment?.equalsIgnoreCase("holidays") == true || ExpressionEvaluation.sheetAggregate(line.expression) != nil ||
                ExpressionEvaluation.isPresentation(line.expression) || line.expression == nil && line.error == nil { continue }
            memberLists[current].append(i); totalMembers.append(i)
            for tag in line.tags { tags.set(tag, (tags[tag] ?? []) + [i]) }
        }
        // C# shares one List per block, so a line sees every member of its block (filtered to earlier lines below).
        for i in 0..<count { blockMembers[i] = memberLists[memberIndex[i]] }
        var dependencies = [[Int]](repeating: [], count: count)
        var aggregateReferences = [[Int]](repeating: [], count: count)
        var references = [NetDictionary<String, Int>](repeating: NetDictionary<String, Int>.ignoringCase(), count: count)
        var consumers = [[Int]](repeating: [], count: count)
        var remaining = [Int](repeating: 0, count: count)
        var results = (0..<count).map { LineResult($0, nil, parsed[$0].error) }
        var edgeCount = 0
        let holidayDefinitions = assignments["holidays"]
        for i in 0..<count {
            try cancellationToken.throwIfCancellationRequested()
            guard let expression = parsed[i].expression else { continue }
            do {
                var required = NetHashSet<Int>()
                let nodes = ExpressionEvaluation.walk(expression)
                if nodes.contains(where: { FunctionLibrary.usesWorkdays($0) || ($0 as? CallExpression).map { functions.library.usesWorkdayCalendar($0.name) } == true }), let holidayDefinitions {
                    let preceding = holidayDefinitions.filter { $0 < i }.count
                    if preceding > 0 { let target = holidayDefinitions[preceding - 1]; references[i].set("\0holidays", target); required.insert(target) }
                }
                var aggregateTargets: NetHashSet<Int>?
                for node in nodes {
                    try cancellationToken.throwIfCancellationRequested()
                    if let call = node as? CallExpression, functions.blockedNames.contains(call.name) { throw CalcError.format("Invalid function definition: \(call.name)") }
                    if let name = node as? NameExpression {
                        var target: Int
                        if let line = SheetSyntax.isLineReference(name.name) { target = line }
                        else if name.name.equalsIgnoreCase("prev") { target = i - 1 }
                        else {
                            guard let definitions = assignments[name.name] else { throw CalcError.format("Unknown variable: \(name.name)") }
                            let preceding = definitions.filter { $0 < i }.count
                            target = preceding > 0 ? definitions[preceding - 1] : definitions[0]
                        }
                        if target < 0 || target >= count { throw CalcError.format("Invalid line reference") }
                        references[i].set(name.name, target); required.insert(target)
                    } else if node is AggregateExpression || (node as? ChartExpression).map({ $0.data == nil }) == true {
                        if aggregateTargets == nil { aggregateTargets = NetHashSet<Int>() }
                        let tag = (node as? AggregateExpression)?.tag ?? (node as? ChartExpression)?.tag
                        let candidates: [Int] = tag == nil ? Array(blockMembers[i].prefix { $0 < i }) : tags[tag!] ?? []
                        for target in candidates {
                            try cancellationToken.throwIfCancellationRequested()
                            required.insert(target)
                            aggregateTargets!.insert(target)
                            if required.count + edgeCount > maxDependencyEdges { throw CalcError.arithmetic("Sheet dependency limit exceeded") }
                        }
                    }
                    if required.count + edgeCount > maxDependencyEdges { throw CalcError.arithmetic("Sheet dependency limit exceeded") }
                }
                dependencies[i] = required.elements.sorted(); edgeCount += required.count
                aggregateReferences[i] = aggregateTargets?.elements.sorted() ?? []
                remaining[i] = required.count
                for target in required { consumers[target].append(i) }
            } catch let e as CalcError where e.isFormatOrArithmetic { results[i] = LineResult(i, nil, e.message) }
        }
        var queue = (0..<count).filter { remaining[$0] == 0 }; var head = 0
        var completed = [Bool](repeating: false, count: count)
        var contextDependencies = [ContextDependency](repeating: [], count: count)
        var currencyRequests = [[DateOnlyKey]](repeating: [], count: count)
        var uuidRequests = NetHashSet<UuidRequest>(); var uuidPending = [Bool](repeating: false, count: count)
        let sheetBudget = SharedExecutionBudget()
        while head < queue.count {
            let i = queue[head]; head += 1
            try cancellationToken.throwIfCancellationRequested()
            completed[i] = true
            if results[i].error == nil, let expression = parsed[i].expression {
                let reads = ContextReads()
                do {
                    // A symbol-set change can turn prose/errors into expressions with the same empty dependency set.
                    func sameContext() -> Bool {
                        guard let cache else { return false }
                        let d = cache.contextDependencies[i]
                        return (!d.contains(.uuid) || cache.uuids?.key(i) == context.uuids?.key(i)) &&
                            (!d.contains(.dice) || cache.uuids?.diceKey(i) == context.uuids?.diceKey(i)) &&
                            (!d.contains(.date) || cache.today == context.today) &&
                            (!d.contains(.payrollRegion) || cache.payrollRegion == context.payrollRegion) &&
                            (!d.contains(.displayCurrency) || cache.displayCurrency == context.displayCurrency) &&
                            (!d.contains(.instant) || cache.now == context.now) &&
                            (!d.contains(.zoneRules) || cache.zoneVersion == context.zones.versionId) &&
                            (!d.contains(.localZone) || cache.localZoneVersion == context.localZone?.version) &&
                            (!d.contains(.workdayCalendar) || cache.workdayRegion == context.workdayRegion && cache.customHolidays == context.customHolidays) &&
                            (!d.contains(.currencyRates) || cache.currencyRateKey == (context.currencyRates ?? .empty).key && cache.currencyDate == context.currencyDate)
                    }
                    func reusable() -> Bool {
                        guard let cache, sameNames, unchanged(i), sameContext(), !cache.uuidPending[i], cache.functionKey == functionKey,
                              cache.results[i].dependencies == dependencies[i], cache.aggregateReferences[i] == aggregateReferences[i] else { return false }
                        if let chart = parsed[i].expression as? ChartExpression, chart.data == nil, !aggregateReferences[i].allSatisfy(unchanged) { return false }
                        let old = cache.references[i]
                        guard old.count == references[i].count, references[i].allSatisfy({ old[$0.key] == $0.value }) else { return false }
                        return dependencies[i].allSatisfy { d in d < cache.results.count && cache.results[d].value == results[d].value && cache.results[d].error == results[d].error }
                    }
                    if reusable() {
                        results[i] = cache!.results[i]; contextDependencies[i] = cache!.contextDependencies[i]; reusedCount += 1
                        currencyRequests[i] = cache!.currencyRequests[i]
                    } else {
                        func read(_ target: Int) throws -> SheetValue {
                            if let value = results[target].value { return value }
                            throw CalcError.format(results[target].pending == nil ? "Dependency L\(target + 1) unavailable" : "L\(target + 1) not rolled yet")
                        }
                        let aggregateValues = try aggregateReferences[i].map(read)
                        var lineContext = context
                        if let holidayLine = references[i]["\0holidays"] { lineContext.customHolidays = try read(holidayLine).holidays }
                        if context.uuids != nil { lineContext.uuidLine = i; lineContext.uuidPath = "" }
                        if let chart = parsed[i].expression as? ChartExpression, chart.data == nil {
                            lineContext.aggregateLabels = try aggregateReferences[i].map { try WorksheetSyntax.label(parsed[$0], sourceLines[$0], $0, cancellationToken) }
                        }
                        let budget = ExecutionBudget(sheetBudget)
                        let lineReferences = references[i]
                        var evaluated = try ExpressionEvaluation.evaluate(expression, { try read(lineReferences[$0]!) }, aggregateValues, cancellationToken,
                            { name, args, callContext in
                                if functions.blockedNames.contains(name) { throw CalcError.format("Invalid function definition: \(name)") }
                                return try functions.library.invoke(name, args, budget, cancellationToken, context: callContext, contextReads: reads)
                            }, budget, functions.library.describe, lineContext, reads)
                        contextDependencies[i] = reads.dependencies
                        let holidayDeclaration = parsed[i].assignment?.equalsIgnoreCase("holidays") == true
                        if holidayDeclaration, case .list(let list) = evaluated.value, list.values.isEmpty { evaluated = (.holidayList(HolidaySet.empty), evaluated.steps) }
                        if holidayDeclaration && evaluated.value.kind != .holidayList { throw CalcError.format("holidays requires a date list") }
                        let (shown, shownStep) = try displayConversion(expression, evaluated.value, lineContext, reads, budget, cancellationToken)
                        contextDependencies[i] = reads.dependencies
                        let line = LineResult(i, evaluated.value, nil)
                        line.isDeclaration = holidayDeclaration; line.isAggregate = ExpressionEvaluation.sheetAggregate(expression) != nil
                        line.dependencies = dependencies[i]; line.explanation = shownStep == nil ? evaluated.steps : evaluated.steps + [shownStep!]; line.shown = shown
                        results[i] = line
                        evaluatedCount += 1
                    }
                } catch let e as DiceUnrolledError {
                    contextDependencies[i] = reads.dependencies
                    let line = LineResult(i, nil, nil); line.pending = e.preview; line.explanation = e.steps; line.dependencies = dependencies[i]; results[i] = line
                } catch let e as CalcError where e.isFormatOrArithmetic {
                    contextDependencies[i] = reads.dependencies
                    let line = LineResult(i, nil, e.message); line.dependencies = dependencies[i]; results[i] = line
                }
                if !reads.uuidRequests.isEmpty {
                    for request in reads.uuidRequests { uuidRequests.insert(request) }
                    if uuidRequests.count > StableUuidContext.maxBindings { throw CalcError.computationLimit }
                }
                uuidPending[i] = !reads.uuidRequests.isEmpty || dependencies[i].contains { uuidPending[$0] }
                if !reads.currencyRequests.isEmpty { currencyRequests[i] = reads.currencyRequests.elements }
            }
            for consumer in consumers[i] { remaining[consumer] -= 1; if remaining[consumer] == 0 { queue.append(consumer) } }
        }
        for i in 0..<count where !completed[i] {
            let line = LineResult(i, nil, "Circular dependency"); line.dependencies = dependencies[i]; results[i] = line
        }
        try cancellationToken.throwIfCancellationRequested()
        let usesCurrentDate = contextDependencies.contains { $0.contains(.date) }
        let usesCurrentInstant = contextDependencies.contains { $0.contains(.instant) }
        let usesLocalTimeZone = contextDependencies.contains { $0.contains(.localZone) }
        let requiresSecondRefresh = contextDependencies.contains { $0.contains(.secondTick) }
        let requestedRates = Array(NetHashSet(currencyRequests.flatMap { $0 }).elements.prefix(CurrencyRateBook.maxHistoricalSnapshots + 2))
        if requestedRates.filter({ $0.date != nil }).count > CurrencyRateBook.maxHistoricalSnapshots { throw CalcError.argument("Currency rate date limit exceeded (64 historical dates)") }
        try cancellationToken.throwIfCancellationRequested()
        if let cache {
            cache.sources = tables.keys; cache.scanned = scanned; cache.parsed = syntax; cache.names = names
            cache.results = results; cache.references = references; cache.statistics = EvaluationStatistics(parsedLines: parsedCount, evaluatedLines: evaluatedCount, reusedResults: reusedCount)
            cache.aggregateReferences = aggregateReferences
            cache.functionKey = functionKey; cache.uuids = context.uuids; cache.uuidPending = uuidPending
            cache.today = context.today
            cache.now = context.now
            cache.zoneVersion = contextDependencies.contains { $0.contains(.zoneRules) } ? context.zones.versionId : nil
            cache.contextDependencies = contextDependencies
            cache.localZoneVersion = usesLocalTimeZone ? context.localZone?.version : nil
            cache.workdayRegion = context.workdayRegion; cache.customHolidays = context.customHolidays
            cache.payrollRegion = context.payrollRegion; cache.displayCurrency = context.displayCurrency
            cache.currencyRateKey = (context.currencyRates ?? .empty).key; cache.currencyDate = context.currencyDate; cache.currencyRequests = currencyRequests
        }
        let published = uuidPending.contains(true) ? results.enumerated().map { uuidPending[$0.offset] ? $0.element.copy(value: nil, error: "UUID generation pending", keepExplanation: false) : $0.element } : results
        let evaluation = SheetEvaluation(published, functions)
        evaluation.usesCurrentDate = usesCurrentDate; evaluation.usesCurrentInstant = usesCurrentInstant
        evaluation.usesLocalTimeZone = usesLocalTimeZone; evaluation.requiresSecondRefresh = requiresSecondRefresh; evaluation.uuidRequests = uuidRequests.elements
        evaluation.usesCurrencyRates = contextDependencies.contains { $0.contains(.currencyRates) }
        evaluation.hasMoney = results.contains { result in
            switch result.value { case .money?, .usagePrice?: return true; case .list(let list)?: return list.hasMoney; default: return false }
        }
        evaluation.totalMembers = totalMembers
        evaluation.currencyRequests = requestedRates.stableSorted { a, b in
            switch (a.date, b.date) { case (nil, nil): return false; case (nil, _): return true; case (_, nil): return false; case let (x?, y?): return x < y }
        }.map { CurrencyRateRequest(date: $0.date) }
        return evaluation
    }

    /// Shows a plain monetary result in the default currency. A line that names its target currency keeps it,
    /// and a missing or incompatible rate leaves the original amount.
    private static func displayConversion(_ expression: Expression, _ value: SheetValue, _ context: EvaluationContext, _ reads: ContextReads, _ budget: ExecutionBudget, _ cancellationToken: CancellationToken) throws -> (SheetValue?, CalculationStep?) {
        guard case .money(let money) = value else { return (nil, nil) }
        reads.dependencies.insert(.displayCurrency)
        guard let target = context.displayCurrency, money.currency != target,
              !ExpressionEvaluation.walk(expression).contains(where: { ($0 as? CurrencyConvertExpression)?.currency == money.currency }) else { return (nil, nil) }
        do {
            let converter = MoneyArithmetic(ExactArithmetic(budget, cancellationToken), context.with { $0.currencyDate = nil }, reads)
            let shown = SheetValue.money(try converter.convert(money, target))
            return (shown, CalculationStep("show in default currency", [try value.display], try shown.display, "Shown in default currency; references keep " + money.currency + "; " + (converter.provenance ?? "")))
        } catch let e as CalcError where e.isArithmetic { return (nil, nil) }
    }
}
