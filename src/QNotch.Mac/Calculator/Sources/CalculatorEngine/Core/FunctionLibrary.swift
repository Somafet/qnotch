import Foundation

struct FunctionDefinition: Hashable { let name: String; let parameters: [String]; let body: String }
struct FunctionReceipt: Hashable { let key: String; let count: Int }
struct FunctionDirective { let key: String; let definition: FunctionDefinition?; let name: String }

/// Immutable, parameter-only function scope. No captured sheet values or host capabilities.
final class FunctionLibrary {
    static let maxFunctions = 128
    static let maxDefinitionCharacters = 64000
    /// Catalog schema rule: 4 marks formula syntax (solve, integral, derivative, pi/e/tau/phi and formula sheet functions); 5 marks complex,
    /// prime, physical-constant, practical-helper, fuel-unit, plot, chart and table syntax. Older readers reject a body above their version.
    static let latestCatalogVersion = 5, formulaCatalogVersion = 4
    private var compiled = NetDictionary<String, (definition: FunctionDefinition, body: Expression)>.ignoringCase()
    private var uuidFunctions = NetHashSet<String>.ignoringCase()
    private var workdayFunctions = NetHashSet<String>.ignoringCase()
    var hasUuid: Bool { !uuidFunctions.isEmpty }
    private(set) var minimumCatalogVersion = 1
    func usesUuid(_ name: String) -> Bool { uuidFunctions.contains(name) }
    func usesWorkdayCalendar(_ name: String) -> Bool { workdayFunctions.contains(name) }
    static let empty = try! FunctionLibrary([])
    let definitions: [FunctionDefinition]
    let fingerprint: String

    init(_ definitions: [FunctionDefinition], _ token: CancellationToken = .none) throws {
        var copies: [FunctionDefinition] = []; var characters = 0
        for definition in definitions {
            try token.throwIfCancellationRequested()
            if !FunctionLibrary.validIdentifier(definition.name, 64) || FunctionLibrary.isBuiltin(definition.name) || SheetSyntax.isReserved(definition.name) || definition.name.equalsIgnoreCase("forget") {
                throw CalcError.format("Invalid or reserved function name")
            }
            if definition.parameters.count > 16 || definition.parameters.contains(where: { !FunctionLibrary.validIdentifier($0, 32) }) ||
                NetHashSet.ignoringCase(definition.parameters).count != definition.parameters.count { throw CalcError.format("Invalid function parameters") }
            if definition.body.netTrim.isEmpty || definition.body.netLength > 4096 { throw CalcError.format("Function body must contain 1–4096 characters") }
            characters += definition.name.netLength + definition.body.netLength + definition.parameters.reduce(0) { $0 + $1.netLength }
            if copies.count == FunctionLibrary.maxFunctions || characters > FunctionLibrary.maxDefinitionCharacters { throw CalcError.arithmetic("Function library limit exceeded") }
            let scopeNames = NetHashSet.ignoringCase(definition.parameters)
            let body = try FunctionLibrary.parseBody(definition.body, scopeNames, token)
            if !compiled.tryAdd(definition.name, (definition, body)) { throw CalcError.format("Duplicate function name") }
            copies.append(definition)
        }
        var graph = NetDictionary<String, NetHashSet<String>>.ignoringCase()
        for (key, value) in compiled {
            let parameters = NetHashSet.ignoringCase(value.definition.parameters)
            var dependencies = NetHashSet<String>.ignoringCase()
            for node in ExpressionEvaluation.walk(value.body) {
                try token.throwIfCancellationRequested()
                if let variable = node as? NameExpression, !parameters.contains(variable.name) { throw CalcError.format("Function \(key) has an unbound parameter: \(variable.name)") }
                if let call = node as? CallExpression {
                    let arity: Int
                    let n = call.name, c = call.arguments.count
                    if RateArithmetic.isFunction(n) { try RateArithmetic.validateArity(n, c); continue }
                    if DeveloperArithmetic.isFunction(n) { try DeveloperArithmetic.validateArity(n, c); continue }
                    if TextArithmetic.isFunction(n) { try TextArithmetic.validateArity(n, c); continue }
                    if NetworkArithmetic.isFunction(n) { try NetworkArithmetic.validateArity(n, c); continue }
                    if IntegerArithmetic.isFunction(n) { try IntegerArithmetic.validateArity(n, c); continue }
                    if PracticalArithmetic.isFunction(n) { try PracticalArithmetic.validateArity(n, c); continue }
                    if HelperArithmetic.isFunction(n) { try HelperArithmetic.validateArity(n, c); continue }
                    if ElectricalArithmetic.isFunction(n) { try ElectricalArithmetic.validateArity(n, c); continue }
                    if MatrixArithmetic.isFunction(n) { try MatrixArithmetic.validateArity(n, c); continue }
                    if ComplexArithmetic.isFunction(n) { try ComplexArithmetic.validateArity(n, c); continue }
                    if PrimeArithmetic.isFunction(n) { try PrimeArithmetic.validateArity(n, c); continue }
                    if RomanianTaxArithmetic.isFunction(n) { try RomanianTaxArithmetic.validateArity(n, c); continue }
                    if StatisticsArithmetic.isFunction(n) { try StatisticsArithmetic.validateArity(n, c); continue }
                    if FinancialArithmetic.isFunction(n) { try FinancialArithmetic.validateArity(n, c); continue }
                    if FunctionLibrary.isBuiltin(n) { arity = FunctionLibrary.builtinArity(n) }
                    else if let callee = compiled[n] { dependencies.insert(n); arity = callee.definition.parameters.count }
                    else { throw CalcError.format("Unknown function: \(n)") }
                    if c != arity { throw CalcError.format("\(n) expects \(arity) argument(s)") }
                }
            }
            graph.set(key, dependencies)
        }
        var depths = NetDictionary<String, Int>.ignoringCase()
        while depths.count < graph.count {
            var progress = false
            for (key, dependencies) in graph {
                try token.throwIfCancellationRequested()
                if depths.containsKey(key) || dependencies.contains(where: { !depths.containsKey($0) }) { continue }
                let depth = dependencies.isEmpty ? 1 : dependencies.map { depths[$0]! }.max()! + 1
                if depth > 32 { throw CalcError.arithmetic("Function call depth limit exceeded") }
                depths.set(key, depth); progress = true
                let body = compiled[key]!.body
                if ExpressionEvaluation.walk(body).contains(where: { $0 is UuidExpression }) || dependencies.contains(where: uuidFunctions.contains) { uuidFunctions.insert(key) }
                if ExpressionEvaluation.walk(body).contains(where: FunctionLibrary.usesWorkdays) || dependencies.contains(where: workdayFunctions.contains) { workdayFunctions.insert(key) }
            }
            if !progress { throw CalcError.format("Recursive functions are not supported") }
        }
        var rateSyntax = false
        for (_, value) in compiled where !rateSyntax {
            rateSyntax = ExpressionEvaluation.walk(value.body).contains { node in
                node is UsageCountExpression || node is UsageConvertExpression || node is UsagePriceExpression || node is RateForExpression || node is TimestampJoinExpression ||
                    (node as? CallExpression).map { RateArithmetic.isFunction($0.name) } == true
            }
            if !rateSyntax {
                let parameters = NetHashSet.ignoringCase(value.definition.parameters)
                rateSyntax = try FunctionLibrary.bodyTokens(value.definition.body, token, parameters).contains { t in
                    t.kind == .name && !parameters.contains(t.text) && (try? RateSyntax.trySpeedUnit(t.text)) != nil
                }
            }
        }
        let latestSyntax = compiled.values.contains { ExpressionEvaluation.walk($0.body).contains(where: FunctionLibrary.requiresLatestCatalog) }
        let formulaSyntax = compiled.values.contains { ExpressionEvaluation.walk($0.body).contains(where: FunctionLibrary.requiresFormulaCatalog) }
        self.definitions = copies
        fingerprint = sha256Hex(try copies.stableSorted { String.ordinalIgnoreCaseCompare($0.name, $1.name) < 0 }.map { try FunctionLibrary.canonical($0) }.joined(separator: "\n"))
        minimumCatalogVersion = latestSyntax ? FunctionLibrary.latestCatalogVersion : formulaSyntax ? FunctionLibrary.formulaCatalogVersion : rateSyntax ? 3 : hasUuid ? 2 : 1
    }
    static func usesWorkdays(_ node: Expression) -> Bool {
        node is WorkdayPeriodExpression || node is WorkdayCountExpression || node is EarningsConvertExpression ||
            ((node as? SalaryExpression).map { $0.outputPeriod == .hour || $0.outputPeriod == .day } ?? false)
    }
    func invoke(_ name: String, _ arguments: [SheetValue], _ budget: ExecutionBudget, _ token: CancellationToken, depth: Int = 0, context: EvaluationContext? = nil, contextReads: ContextReads? = nil) throws -> (value: SheetValue, steps: [CalculationStep]) {
        try budget.step(token)
        if depth >= 32 { throw CalcError.arithmetic("Function call depth limit exceeded") }
        guard let function = compiled[name] else { throw CalcError.format("Unknown function: \(name)") }
        if arguments.count != function.definition.parameters.count { throw CalcError.format("\(name) expects \(function.definition.parameters.count) argument(s)") }
        var scope = NetDictionary<String, SheetValue>.ignoringCase()
        for (index, parameter) in function.definition.parameters.enumerated() { scope.set(parameter, arguments[index]) }
        return try ExpressionEvaluation.evaluate(function.body, { scope[$0]! }, [], token,
            { callee, args, callContext in try self.invoke(callee, args, budget, token, depth: depth + 1, context: callContext, contextReads: contextReads) },
            budget, describe, context, contextReads)
    }
    func describe(_ name: String) -> String? {
        guard let function = compiled[name] else { return nil }
        let text = function.definition.name + "(" + function.definition.parameters.joined(separator: ", ") + ") = " + function.definition.body
        return text.netLength <= 256 ? text : text.netSubstring(0, 256) + "…"
    }
    static func requiresFormulaCatalog(_ node: Expression) -> Bool {
        node is EquationExpression || node is IntegralExpression || node is DerivativeExpression || node is ConstantExpression ||
            ((node as? CallExpression).map { FormulaFunctions.isSheetFunction($0.name) || EquationSyntax.function($0.name) } ?? false)
    }
    static func requiresLatestCatalog(_ node: Expression) -> Bool {
        if let constant = node as? ConstantExpression, !FormulaFunctions.isConstant(constant.name) { return true }
        if node is ImaginaryExpression || node is HelperExpression || node is PlotExpression || node is ChartExpression || node is TableExpression { return true }
        if let unit = node as? UnitExpressionNode, unit.unit.fuelForm() != 0 { return true }
        if let call = node as? CallExpression { return ComplexArithmetic.isFunction(call.name) || PrimeArithmetic.isFunction(call.name) || HelperArithmetic.isFunction(call.name) || TableArithmetic.isFunction(call.name) }
        return false
    }
    static func parseBody(_ body: String, _ scopeNames: NetHashSet<String>, _ token: CancellationToken) throws -> Expression {
        if EquationSyntax.prefix(body) { return try EquationSyntax.parse(body, scopeNames, token) }
        let tokens = try ExpressionParser.tokenize(body, token, scopeNames)
        return try WorksheetSyntax.tryParse(tokens, scopeNames, token) ?? ExpressionParser(tokens, token, scopeNames).parse()
    }
    private static func bodyTokens(_ body: String, _ token: CancellationToken, _ scopeNames: NetHashSet<String>) throws -> [Token] {
        EquationSyntax.prefix(body) ? try EquationSyntax.sides(body).flatMap { try ExpressionParser.tokenize($0, token, scopeNames) } : try ExpressionParser.tokenize(body, token, scopeNames)
    }
    static func isBuiltin(_ name: String) -> Bool {
        TableArithmetic.isFunction(name) || ComplexArithmetic.isFunction(name) || PrimeArithmetic.isFunction(name) || RateArithmetic.isFunction(name) || name.equalsIgnoreCase("uuid") ||
            FormulaFunctions.isSheetFunction(name) || EquationSyntax.function(name) || CalculusSyntax.isFunction(name) || DeveloperArithmetic.isFunction(name) || TextArithmetic.isFunction(name) ||
            NetworkArithmetic.isFunction(name) || IntegerArithmetic.isFunction(name) || PracticalArithmetic.isFunction(name) || HelperArithmetic.isFunction(name) || ElectricalArithmetic.isFunction(name) ||
            MatrixArithmetic.isFunction(name) || RomanianTaxArithmetic.isFunction(name) || StatisticsArithmetic.isFunction(name) || FinancialArithmetic.isFunction(name) ||
            ["share", "whole", "beforediscount", "change", "markup", "margin", "abs", "sqrt"].contains(name.netLower)
    }
    static func builtinArity(_ name: String) -> Int {
        EquationSyntax.function(name) ? EquationSyntax.arity(name) : CalculusSyntax.isFunction(name) ? CalculusSyntax.arity(name) :
            FormulaFunctions.isSheetFunction(name) || ["abs", "sqrt"].contains(name.netLower) ? 1 : 2
    }
    static func validIdentifier(_ value: String?, _ limit: Int) -> Bool {
        guard let value else { return false }
        let u = value.units
        guard !u.isEmpty, u.count <= limit, NetChar.isLetter(u[0]) || u[0] == 0x5F else { return false }
        return u.allSatisfy { NetChar.isLetterOrDigit($0) || $0 == 0x5F || KeywordCatalog.isMark($0) }
    }
    static func hash(_ value: String) -> String { sha256Hex(value) }
    static func canonical(_ definition: FunctionDefinition) throws -> String {
        let parameters = NetHashSet.ignoringCase(definition.parameters)
        // Ordinary names remain case-insensitive; chemical literals are not (Co is cobalt, CO carbon monoxide).
        let body = try parseBody(definition.body, parameters, .none)
        let formulas = ExpressionEvaluation.walk(body).compactMap { ($0 as? ChemistryExpression)?.formula }
        func text(_ source: String) throws -> String {
            let tokens = try ExpressionParser.tokenize(source, .none, parameters)
            return try tokens.indices.map { i -> String in
                if tokens[i].kind == .text { return "@TEXT:" + tokens[i].text }
                if i > 0 && tokens[i - 1].kind == .time && TimeSyntax.isMeridiem(tokens[i].text) { return "@MERIDIEM:" + tokens[i].text.netUpper }
                if i > 0 && tokens[i].joinedToPrevious && tokens[i - 1].kind == .number && NumberLanguage.isShortSuffix(tokens[i].text) { return NumberLanguage.canonicalToken(tokens, i) }
                return try UnitCatalog.canonicalToken(tokens, i, parameters) ?? NumberLanguage.canonicalToken(tokens, i)
            }.joined(separator: " ")
        }
        let canonicalBody = EquationSyntax.prefix(definition.body) ? "SOLVE " + (try EquationSyntax.sides(definition.body).map(text)).joined(separator: " = ") : try text(definition.body)
        return definition.name.netUpper + "(" + definition.parameters.map { $0.netUpper }.joined(separator: ",") + ")=" + canonicalBody +
            (formulas.isEmpty ? "" : "|CHEM:" + formulas.joined(separator: "|"))
    }
}

/// Pure proposed save. Persistence belongs to Documents, never evaluation.
final class FunctionUpdate {
    let library: FunctionLibrary
    let receipts: [FunctionReceipt]
    let sourceHash: String
    let hasChanges: Bool
    var baseFingerprint = ""
    var errors: [Int: String] = [:]
    var blockedNames = NetHashSet<String>.ignoringCase()
    init(_ library: FunctionLibrary, _ receipts: [FunctionReceipt], _ sourceHash: String, _ hasChanges: Bool) {
        self.library = library; self.receipts = receipts; self.sourceHash = sourceHash; self.hasChanges = hasChanges
    }
    var cacheKey: String { library.fingerprint + ":" + blockedNames.elements.stableSorted { String.ordinalIgnoreCaseCompare($0, $1) < 0 }.joined(separator: ",") }

    static func prepare(_ source: String, _ library: FunctionLibrary, _ receipts: [FunctionReceipt], _ token: CancellationToken = .none) throws -> FunctionUpdate {
        if source.netLength > SheetEvaluator.maxCharacters { throw CalcError.argument("Sheet exceeds 200,000 characters") }
        let lines = SheetEvaluator.splitLines(source)
        if lines.count > SheetEvaluator.maxLines { throw CalcError.argument("Sheet exceeds 10,000 lines") }
        let tables = try TableSyntax.layout(lines, token)
        return try prepare(source, try lines.indices.map { try tables.scan($0, lines, token) ?? SheetSyntax.scan(lines[$0], token) }, library, receipts, token)
    }
    static func prepare(_ source: String, _ lines: [ParsedLine], _ library: FunctionLibrary, _ receipts: [FunctionReceipt], _ token: CancellationToken) throws -> FunctionUpdate {
        try validateReceipts(receipts)
        var before: [String: Int] = [:]
        for receipt in receipts { if before[receipt.key] != nil { throw CalcError.argument("An item with the same key has already been added. Key: " + receipt.key) }; before[receipt.key] = receipt.count }
        var seen = NetDictionary<String, Int>()
        var proposed = NetDictionary<String, FunctionDefinition>.ignoringCase()
        for definition in library.definitions { if !proposed.tryAdd(definition.name, definition) { throw CalcError.argument("An item with the same key has already been added. Key: " + definition.name) } }
        var pending: [(line: Int, command: FunctionDirective)] = []
        var errors: [Int: String] = [:]; var blocked = NetHashSet<String>.ignoringCase()
        var directiveCount = 0
        for (index, line) in lines.enumerated() {
            try token.throwIfCancellationRequested()
            if let invalidName = line.functionName, line.error != nil { blocked.insert(invalidName) }
            guard let command = line.directive else { continue }
            let count = (seen[command.key] ?? 0) + 1; seen.set(command.key, count)
            directiveCount += 1
            if directiveCount > 256 { errors[index] = "Function directive limit exceeded"; blocked.insert(command.name); continue }
            if count <= before[command.key] ?? 0 { continue }
            pending.append((index, command))
            if let definition = command.definition { proposed.set(command.name, definition) } else { proposed.remove(command.name) }
        }
        var projected = library
        if !pending.isEmpty && errors.isEmpty && blocked.isEmpty {
            do { projected = try FunctionLibrary(proposed.values, token) }
            catch let e as CalcError where e.isFormatOrArithmetic { for entry in pending { errors[entry.line] = e.message; blocked.insert(entry.command.name) } }
        }
        if !blocked.isEmpty || !errors.isEmpty {
            for entry in pending { if errors[entry.line] == nil { errors[entry.line] = "Function changes not applied; fix invalid definitions" }; blocked.insert(entry.command.name) }
        }
        let clean = errors.isEmpty && blocked.isEmpty
        let next = seen.keys.sorted { String.ordinalCompare($0, $1) < 0 }.map { FunctionReceipt(key: $0, count: clean ? seen[$0]! : min(seen[$0]!, before[$0] ?? 0)) }.filter { $0.count > 0 }
        let changed = projected.fingerprint != library.fingerprint || receipts.stableSorted { String.ordinalCompare($0.key, $1.key) < 0 } != next
        let update = FunctionUpdate(projected, next, sha256Hex(source), changed)
        update.baseFingerprint = library.fingerprint; update.errors = errors; update.blockedNames = blocked
        return update
    }
    static func validateReceipts(_ receipts: [FunctionReceipt]) throws {
        if receipts.count > 256 || receipts.contains(where: { $0.key.netLength != 64 || !$0.key.utf16.allSatisfy(NetChar.isAsciiHexDigit) || $0.count < 1 || $0.count > 256 }) ||
            Set(receipts.map(\.key)).count != receipts.count || receipts.reduce(0, { $0 + $1.count }) > 256 { throw CalcError.format("Invalid function receipts") }
    }
}
