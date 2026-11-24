import Foundation

/// UUIDs and dice rolls a sheet holds (C# GeneratedUuidSession), so `uuid` lines keep their value and a roll stays rolled across edits,
/// restarts and other computers. Identities follow their statements through text edits; an edit's identity change joins the editor's undo
/// step (Windows UuidEditorBinding). Main thread only: the evaluation gets an immutable `CalculatorUuidContext`.
public final class CalculatorGeneratedValues {
    let session: GeneratedUuidSession
    private var stateLines: IndexSet?

    /// A sheet without saved values (a new sheet, or one written before generated values).
    public init(source: String) {
        // A fresh session cannot fail for text the editor accepts; an over-long text is refused by the evaluation anyway.
        session = (try? GeneratedUuidSession(source)) ?? (try! GeneratedUuidSession(""))
    }

    /// The values a saved sheet holds. A damaged state is refused by the store already; this one is valid.
    public init(_ sheet: CalculatorSavedSheet) throws {
        session = try CalculatorDocumentError.wrap { try GeneratedUuidSession(sheet.source, sheet.document.generatedUuids) }
    }

    /// The text the identities belong to.
    public var source: String { session.source }
    public var hasDice: Bool { session.hasDice }

    var snapshot: GeneratedUuidState? { session.snapshot }

    /// Lines (zero-based) holding a UUID value or a roll.
    public var linesWithValues: IndexSet {
        if let stateLines { return stateLines }
        var lines = IndexSet()
        if let state = session.snapshot {
            var rows: [UUID: Int] = [:]
            for (index, id) in state.statements.enumerated() where rows[id] == nil { rows[id] = index }
            for binding in state.bindings { if let row = rows[binding.statement] { lines.insert(row) } }
            for roll in state.dice ?? [] { if let row = rows[roll.statement] { lines.insert(row) } }
        }
        stateLines = lines
        return lines
    }

    /// Moves identities with their statements across one text edit. `range` is the replaced UTF-16 range of the old text and
    /// `replacementLength` the inserted length; without a range the edit is found by comparing the texts. The returned edit undoes and
    /// redoes the identity change; nil when the text was refused.
    @discardableResult
    public func apply(_ source: String, range: NSRange? = nil, replacementLength: Int = 0) -> CalculatorGeneratedEdit? {
        stateLines = nil
        do {
            let edit = if let range { try session.apply(source, range.location, range.length, replacementLength) } else { try session.apply(source) }
            return CalculatorGeneratedEdit(edit, self)
        } catch {
            // The text and the edit disagree (or the text is over the limit): fall back to comparing the texts.
            return (try? session.apply(source)).map { CalculatorGeneratedEdit($0, self) }
        }
    }

    /// Follows the editor's text during its own undo and redo, whose registered edits move the identities.
    public func replaySource(_ source: String) {
        stateLines = nil
        session.replaySource(source)
    }

    /// The text and every identity, value and roll as they are now, to come back to on undo or redo.
    public func checkpoint() -> CalculatorGeneratedCheckpoint { CalculatorGeneratedCheckpoint(source: session.source, state: session.snapshot) }

    /// Puts a checkpoint's identities back, whatever edits came between (the editor's undo and redo).
    public func restore(_ checkpoint: CalculatorGeneratedCheckpoint) {
        stateLines = nil
        if (try? session.restore(checkpoint.source, checkpoint.state)) == nil { _ = try? session.apply(checkpoint.source) }
    }

    /// Adopts a restored version's exact identities; the edit joins the text replacement's undo step.
    public func restore(_ sheet: CalculatorSavedSheet) throws -> CalculatorGeneratedEdit {
        stateLines = nil
        return CalculatorGeneratedEdit(try CalculatorDocumentError.wrap { try session.restore(sheet.source, sheet.document.generatedUuids) }, self)
    }

    /// The values an evaluation of `source` reads (Windows ReadUuidContext). The first `uuid` in a sheet turns generated values on, so the
    /// sheet must be saved: `enabled` says so. Nil context when the sheet cannot read any.
    public func context(for source: String, functions: CalculatorFunctions?) -> (context: CalculatorUuidContext?, enabled: Bool) {
        guard session.source == source else { return (nil, false) }
        var enabled = false
        if !session.enabled, (try? UuidSyntax.requiresState(source, functions?.library)) == true { enabled = session.enable() }
        if enabled { stateLines = nil }
        if source.netUpper.netIndexOf("UUID") < 0, !source.contains("("), !session.hasDice { return (nil, enabled) }
        return ((try? session.context).flatMap { $0 }.map(CalculatorUuidContext.init), enabled)
    }

    /// Gives the lines an evaluation found without a UUID their new values. The sheet must then be saved and evaluated again.
    public func supply(_ evaluation: CalculatorEvaluation) throws {
        guard let observed = evaluation.raw.uuids, !evaluation.raw.uuidRequests.isEmpty else { return }
        stateLines = nil
        try CalculatorDocumentError.wrap { try session.supply(evaluation.raw.uuidRequests, observed) }
    }

    /// Rolls a dice line with the system's cryptographic generator. Without `again`, a line that already holds a roll of its formula keeps
    /// it. Nil when nothing was rolled. Throws when the sheet holds too many rolls.
    @discardableResult
    public func roll(line: Int, again: Bool) throws -> CalculatorDiceRoll? {
        stateLines = nil
        return try CalculatorDocumentError.wrap { try session.roll(line, again).flatMap { CalculatorDiceRoll(line: line, $0) } }
    }

    /// The roll a line holds.
    public func rolled(line: Int) -> CalculatorDiceRoll? { session.rolled(line).flatMap { CalculatorDiceRoll(line: line, $0) } }
}

/// Generated values at one moment (`CalculatorGeneratedValues.checkpoint`).
public struct CalculatorGeneratedCheckpoint {
    public let source: String
    let state: GeneratedUuidState?
}

/// One identity change, undone and redone with the text edit it belongs to.
public final class CalculatorGeneratedEdit {
    private let edit: GeneratedUuidEdit
    private weak var owner: CalculatorGeneratedValues?
    init(_ edit: GeneratedUuidEdit, _ owner: CalculatorGeneratedValues) { self.edit = edit; self.owner = owner }
    public func undo() throws { try CalculatorDocumentError.wrap { try edit.undo() } }
    public func redo() throws { try CalculatorDocumentError.wrap { try edit.redo() } }
}

/// The UUID values and rolls an evaluation reads. Immutable.
public final class CalculatorUuidContext: @unchecked Sendable {
    let context: StableUuidContext
    init(_ context: StableUuidContext) { self.context = context }
}

/// A dice line's roll, die by die, for showing the toss.
public struct CalculatorDiceRoll: Hashable, Sendable {
    public struct Die: Hashable, Sendable {
        public let sides: Int
        public let face: Int
        /// False for a die a keep/drop rule leaves out of the total.
        public let kept: Bool
    }
    public let line: Int
    public let formula: String
    public let faces: [Int]
    public let dice: [Die]

    init?(line: Int, _ binding: DiceBinding) {
        guard let parsed = try? DiceSyntax.tryParse(binding.formula), let dice = try? DiceSyntax.faces(parsed, binding.faces) else { return nil }
        self.line = line
        formula = binding.formula
        faces = binding.faces
        self.dice = dice.map { Die(sides: $0.sides, face: $0.face, kept: $0.kept) }
    }

    /// What a roll key on this line does: Return submits it, ⌘Return rolls again (Windows Enter and Ctrl+Enter).
    public static let rollNote = DiceSyntax.rollNote
}
