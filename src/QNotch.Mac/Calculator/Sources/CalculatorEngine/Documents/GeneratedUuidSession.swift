import Foundation

/// Version 1 holds UUIDs only. Version 2 adds dice rolls, so binaries that predate dice refuse instead of dropping them.
struct GeneratedUuidState: Equatable {
    var version: Int
    var statements: [UUID]
    var bindings: [UuidBinding]
    /// Omitted from JSON when null (JsonIgnoreCondition.WhenWritingNull).
    var dice: [DiceBinding]?
    var nulls = JSONNulls()
    init(_ version: Int, _ statements: [UUID], _ bindings: [UuidBinding], dice: [DiceBinding]? = nil) {
        self.version = version; self.statements = statements; self.bindings = bindings; self.dice = dice
    }
    func with(_ change: (inout GeneratedUuidState) -> Void) -> GeneratedUuidState { var copy = self; change(&copy); return copy }

    static func decode(_ json: NetJSON.Reader) throws -> GeneratedUuidState {
        let statements = try json.array("Statements") { try NetJSON.Reader.guid($0, "Statements") }
        let bindings = try json.array("Bindings") { item in
            try NetJSON.Reader.element(item) { b -> UuidBinding? in
                guard let site = try b.string("Site") else { _ = try b.guid("Statement"); _ = try b.guid("Value"); return nil }
                return UuidBinding(statement: try b.guid("Statement"), site: site, value: try b.guid("Value"))
            } ?? nil
        }
        let dice = try json.array("Dice") { item in
            try NetJSON.Reader.element(item) { d -> DiceBinding? in
                let statement = try d.guid("Statement"), formula = try d.string("Formula")
                let faces = try d.array("Faces") { try NetJSON.Reader.int($0, "Faces") }
                guard let formula, let faces else { return nil }
                return DiceBinding(statement: statement, formula: formula, faces: faces)
            } ?? nil
        }
        var state = GeneratedUuidState(try json.int("Version"), statements ?? [], bindings?.compactMap { $0 } ?? [], dice: dice?.compactMap { $0 })
        if statements == nil || bindings == nil { state.nulls.insert("Statements") }
        if bindings?.contains(where: { $0 == nil }) == true { state.nulls.insert("Binding") }
        if dice?.contains(where: { $0 == nil }) == true { state.nulls.insert("Dice") }
        return state
    }
    var json: String {
        NetJSON.object([("Version", NetJSON.int(version)), ("Statements", NetJSON.array(statements.map(NetJSON.guid))),
                        ("Bindings", NetJSON.array(bindings.map { NetJSON.object([("Statement", NetJSON.guid($0.statement)), ("Site", NetJSON.string($0.site)), ("Value", NetJSON.guid($0.value))]) })),
                        ("Dice", dice.map { NetJSON.array($0.map { NetJSON.object([("Statement", NetJSON.guid($0.statement)), ("Formula", NetJSON.string($0.formula)),
                                                                                   ("Faces", NetJSON.array($0.faces.map { String($0) }))]) }) })])
    }
}

/// Document identity edits are paired with text edits by the host undo stack. No timer or provider.
final class GeneratedUuidSession {
    /// One statement's identity and generated values. Compared by reference, as in C#.
    final class StatementState {
        private var id: UUID
        /// Site → value, in insertion order; sites compare by UTF-16 code units (StringComparer.Ordinal).
        private(set) var values: [(site: String, value: UUID)] = []
        /// The statement's current roll. Rolling replaces it in place; rolls are not undo steps.
        var dice: (formula: String, faces: [Int])?
        init(_ initialId: UUID = .netEmpty) { id = initialId }
        /// An empty identity is created on first use, as C#'s lazy `Id` does.
        var identity: UUID { if id.isNetEmpty { id = UUID.netNew() }; return id }
        func containsSite(_ site: String) -> Bool { values.contains { $0.site.ordinalEquals(site) } }
        func add(_ site: String, _ value: UUID) throws {
            if containsSite(site) { throw CalcError.argument("An item with the same key has already been added. Key: " + site) }
            values.append((site, value))
        }
        var hasState: Bool { !values.isEmpty || dice != nil }
    }

    private var statements: [StatementState]
    private(set) var source: String
    private(set) var enabled: Bool

    init(_ source: String, _ saved: GeneratedUuidState? = nil) throws {
        self.source = source
        if let saved { try GeneratedUuidSession.validate(source, saved) }
        enabled = saved != nil
        statements = try GeneratedUuidSession.rows(source, saved)
    }

    private static func rows(_ source: String, _ saved: GeneratedUuidState?) throws -> [StatementState] {
        guard let saved else { return (0..<(try count(source))).map { _ in StatementState() } }
        let rows = saved.statements.map { StatementState($0) }
        var byId: [UUID: StatementState] = [:]
        for row in rows where byId[row.identity] == nil { byId[row.identity] = row }
        for value in saved.bindings { try byId[value.statement]!.add(value.site, value.value) }
        for roll in try current(saved.dice) { byId[roll.statement]!.dice = (roll.formula, roll.faces) }
        return rows
    }
    private static func count(_ source: String) throws -> Int { min(try SourceLineMap(source).count, SheetEvaluator.maxLines) }

    static func validate(_ source: String, _ state: GeneratedUuidState) throws {
        if state.version != 1 && state.version != 2 { throw DocumentError.unsupportedVersion }
        let lines = try count(source)
        if state.nulls.contains("Statements") || state.statements.count != lines || (state.version == 2) != (state.dice.map { !$0.isEmpty } ?? false) {
            throw CalcError.invalidData("Invalid generated UUID state; original preserved")
        }
        if state.nulls.contains("Dice") { throw CalcError.invalidData("Invalid dice rolls; original preserved") }
        if state.nulls.contains("Binding") { throw CalcError.invalidData("Invalid or excessive UUID bindings") }
        do { _ = try StableUuidContext(state.statements, state.bindings, try current(state.dice)) }
        catch let e as CalcError where e.isArgument { throw CalcError.invalidData(e.message) }
    }

    /// Rolls that still belong to their formula. A roll saved under an earlier meaning of its notation (before 18 November 2026,
    /// `crit` was the crunchy critical with half the dice) no longer fits; it is dropped and the line waits for Enter, never misread.
    private static func current(_ rolls: [DiceBinding]?) throws -> [DiceBinding] {
        guard let rolls else { return [] }
        return try rolls.filter { roll in
            guard let formula = try DiceSyntax.tryParse(roll.formula) else { return false }
            return formula.notation.ordinalEquals(roll.formula) && formula.fits(roll.faces)
        }
    }

    @discardableResult
    func enable() -> Bool { if enabled { return false }; enabled = true; return true }
    private func bindings() -> [UuidBinding] {
        statements.flatMap { row in row.values.map { UuidBinding(statement: row.identity, site: $0.site, value: $0.value) } }
    }
    private func rolls() -> [DiceBinding] {
        statements.compactMap { row in row.dice.map { DiceBinding(statement: row.identity, formula: $0.formula, faces: $0.faces) } }
    }
    var context: StableUuidContext? { get throws { enabled ? try StableUuidContext(statements.map(\.identity), bindings(), rolls()) : nil } }
    var snapshot: GeneratedUuidState? {
        if !enabled { return nil }
        let rolls = rolls()
        return GeneratedUuidState(rolls.isEmpty ? 1 : 2, statements.map(\.identity), bindings(), dice: rolls.isEmpty ? nil : rolls)
    }
    var hasDice: Bool { statements.contains { $0.dice != nil } }
    /// The roll currently held by a line, if any.
    func rolled(_ line: Int) -> DiceBinding? {
        guard line >= 0 && line < statements.count, let roll = statements[line].dice else { return nil }
        return DiceBinding(statement: statements[line].identity, formula: roll.formula, faces: roll.faces)
    }
    /// Rolls a dice line with the OS's cryptographic generator. Without `again`, a line that already holds a roll of its current
    /// formula keeps it. Returns the new roll, or nil when nothing was rolled.
    @discardableResult
    func roll(_ line: Int, _ again: Bool) throws -> DiceBinding? { try roll(line, again, try DiceSyntax.formulas(source)) }
    /// Rolls every unrolled dice line, for one-shot evaluation (CLI and MCP).
    @discardableResult
    func rollAll() throws -> Int {
        let formulas = try DiceSyntax.formulas(source); var rolled = 0
        for line in formulas.keys.sorted() where try roll(line, false, formulas) != nil { rolled += 1 }
        return rolled
    }
    /// Copies another session's rolls for the same leading lines, e.g. a sheet with an appended total.
    func adoptRolls(_ other: GeneratedUuidSession) throws {
        let formulas = try DiceSyntax.formulas(source)
        for i in 0..<min(statements.count, other.statements.count) {
            if let roll = other.statements[i].dice, let formula = formulas[i], formula.notation.ordinalEquals(roll.formula) {
                statements[i].dice = (roll.formula, roll.faces); enabled = true
            }
        }
    }
    private func roll(_ line: Int, _ again: Bool, _ formulas: NetDictionary<Int, DiceFormula>) throws -> DiceBinding? {
        guard line >= 0 && line < statements.count, let formula = formulas[line] else { return nil }
        let row = statements[line]
        if !again, let held = row.dice, held.formula.ordinalEquals(formula.notation), formula.fits(held.faces) { return nil }
        let others = statements.filter { $0 !== row && $0.dice != nil }
        if others.count >= StableUuidContext.maxDiceBindings || others.reduce(0, { $0 + $1.dice!.faces.count }) + formula.sides.count > StableUuidContext.maxDiceFaces {
            throw CalcError.arithmetic("Dice roll limit exceeded")
        }
        var generator = SystemRandomNumberGenerator()
        let faces = formula.sides.map { Int.random(in: 1...$0, using: &generator) }
        row.dice = (formula.notation, faces); enabled = true
        return DiceBinding(statement: row.identity, formula: formula.notation, faces: faces)
    }

    func supply(_ requests: [UuidRequest], _ observed: StableUuidContext) throws {
        if !enabled { throw CalcError.invalidOperation("UUID generation is not enabled") }
        var unique: [UuidRequest] = []
        for request in requests where !unique.contains(where: { $0.line == request.line && $0.site.ordinalEquals(request.site) }) { unique.append(request) }
        let additions = unique.filter { $0.line >= 0 && $0.line < statements.count && StableUuidContext.validSite($0.site) && !statements[$0.line].containsSite($0.site) }
        for r in requests {
            let stale: Bool
            if r.line < 0 || r.line >= statements.count || !StableUuidContext.validSite(r.site) { stale = true }
            else { stale = try observed.statement(r.line) != statements[r.line].identity }
            if stale { throw CalcError.invalidOperation("Stale UUID generation requests") }
        }
        let existing = bindings()
        if existing.count + additions.count > StableUuidContext.maxBindings ||
            existing.reduce(0, { $0 + $1.site.netLength }) + additions.reduce(0, { $0 + $1.site.netLength }) > StableUuidContext.maxSiteCharacters {
            throw CalcError.arithmetic("UUID binding limit exceeded")
        }
        for request in additions { try statements[request.line].add(request.site, UUID.netNew()) }
    }

    func replaySource(_ source: String) { self.source = source }

    /// Adopts a restored document's exact identities. The returned edit joins the source replacement's undo group.
    @discardableResult
    func restore(_ source: String, _ saved: GeneratedUuidState?) throws -> GeneratedUuidEdit {
        if let saved { try GeneratedUuidSession.validate(source, saved) }
        let rows = try GeneratedUuidSession.rows(source, saved)
        let edit = GeneratedUuidEdit(self, 0, statements, rows, enabled, saved != nil)
        statements = rows; self.source = source; enabled = saved != nil
        return edit
    }

    /// Moves identities with their statements across one text edit. Without an explicit range the edit is the longest common prefix
    /// and suffix of the old and new text. Coordinates are UTF-16 code units.
    @discardableResult
    func apply(_ source: String, _ offset: Int? = nil, _ removalLength: Int = 0, _ insertionLength: Int = 0) throws -> GeneratedUuidEdit {
        let new = Array(source.utf16), old = Array(self.source.utf16)
        if new.count > SheetStore.maxCharacters { throw CalcError.argument("Source exceeds document limit") }
        let oldMap = try SourceLineMap(self.source), next = try SourceLineMap(source)
        var offset = offset, removalLength = removalLength, insertionLength = insertionLength
        if offset == nil || offset == 0 && removalLength == old.count && insertionLength == new.count {
            var prefix = 0; while prefix < old.count && prefix < new.count && old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0; while suffix < old.count - prefix && suffix < new.count - prefix && old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
            offset = prefix; removalLength = old.count - prefix - suffix; insertionLength = new.count - prefix - suffix
        }
        let at = offset!
        if at < 0 || removalLength < 0 || insertionLength < 0 || at + removalLength > old.count || new.count != old.count - removalLength + insertionLength {
            throw CalcError.argument("Invalid source identity edit")
        }
        if old[0..<at] != new[0..<at] || old[(at + removalLength)...] != new[(at + insertionLength)...] {
            throw CalcError.argument("Source edit does not match its transaction")
        }
        var ids = [StatementState?](repeating: nil, count: min(next.count, SheetEvaluator.maxLines))
        let delta = insertionLength - removalLength
        for i in 0..<min(statements.count, oldMap.count) {
            let start = oldMap.start(i), end = oldMap.contentEnd(i)
            let target: Int
            if start >= at + removalLength { target = start + delta }
            else if end <= at { target = start }
            else if statements[i].hasState { target = start }
            else { continue }
            if target < 0 || target > new.count { continue }
            let line = try next.lineAt(target)
            if line >= ids.count || ids[line] != nil { continue }
            if next.start(line) != target && !statements[i].hasState { continue }
            let oldText = old[start..<end], newText = new[next.start(line)..<next.contentEnd(line)]
            if oldText != newText {
                if !statements[i].hasState { continue }
                guard let identity = try UuidSyntax.expressionIdentity(String(units: oldText)),
                      let other = try UuidSyntax.expressionIdentity(String(units: newText)), identity.ordinalEquals(other) else { continue }
            }
            ids[line] = statements[i]
        }
        let rows = ids.map { $0 ?? StatementState() }
        var first = 0; while first < statements.count && first < rows.count && statements[first] === rows[first] { first += 1 }
        var tail = 0
        while tail < statements.count - first && tail < rows.count - first && statements[statements.count - tail - 1] === rows[rows.count - tail - 1] { tail += 1 }
        let edit = GeneratedUuidEdit(self, first, Array(statements[first..<(statements.count - tail)]), Array(rows[first..<(rows.count - tail)]))
        statements = rows; self.source = source
        return edit
    }

    func patch(_ index: Int, _ expected: [StatementState], _ replacement: [StatementState], _ enabled: Bool?) throws {
        if index < 0 || index + expected.count > statements.count || !zip(statements[index..<(index + expected.count)], expected).allSatisfy({ $0 === $1 }) {
            throw CalcError.invalidOperation("UUID identity undo does not match the source transaction")
        }
        statements.replaceSubrange(index..<(index + expected.count), with: replacement)
        self.enabled = enabled ?? self.enabled
    }
}

final class GeneratedUuidEdit {
    private let session: GeneratedUuidSession
    private let index: Int
    private let before: [GeneratedUuidSession.StatementState], after: [GeneratedUuidSession.StatementState]
    private let enabledBefore: Bool?, enabledAfter: Bool?
    init(_ session: GeneratedUuidSession, _ index: Int, _ before: [GeneratedUuidSession.StatementState], _ after: [GeneratedUuidSession.StatementState],
         _ enabledBefore: Bool? = nil, _ enabledAfter: Bool? = nil) {
        self.session = session; self.index = index; self.before = before; self.after = after; self.enabledBefore = enabledBefore; self.enabledAfter = enabledAfter
    }
    func undo() throws { try session.patch(index, after, before, enabledBefore) }
    func redo() throws { try session.patch(index, before, after, enabledAfter) }
}
