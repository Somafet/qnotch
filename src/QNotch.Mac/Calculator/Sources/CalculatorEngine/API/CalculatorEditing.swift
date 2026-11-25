import Foundation

/// Renaming a sheet variable everywhere it is defined and used (C# VariableRename, Windows SheetEditor.Rename).
/// Ranges are UTF-16, so they are NSRanges of the editor's text as they are.
public enum CalculatorRename {
    public enum Problem: Sendable { case invalid, taken }
    /// The variable under the caret, or exactly covered by a selection.
    public struct Target: Hashable, Sendable {
        public let name: String
        public let range: NSRange
    }

    /// The variable at a caret (empty selection) or exactly covered by `selection` (surrounding spaces ignored), or nil.
    public static func find(in text: String, selection: NSRange) -> Target? {
        guard let found = try? VariableRename.find(text, selection.location, selection.length) else { return nil }
        return Target(name: found.name, range: NSRange(location: found.span.start, length: found.span.length))
    }

    /// Why `newName` may not replace `name`, or nil when it may.
    public static func check(_ text: String, renaming name: String, to newName: String) -> Problem? {
        switch (try? VariableRename.check(text, name, newName)) ?? .invalid {
        case .none: nil
        case .invalid: .invalid
        case .taken: .taken
        }
    }

    /// Every definition and reference of `name`, in source order.
    public static func occurrences(of name: String, in text: String) -> [NSRange] {
        ((try? VariableRename.occurrences(text, name)) ?? []).map { NSRange(location: $0.start, length: $0.length) }
    }

    /// The spelling a name is written with: words separated by single spaces.
    public static func normalize(_ name: String) -> String { VariableRename.normalize(name) }
}

/// What the sheet makes of pasted text (Windows SheetEditor.CheckPaste).
public enum CalculatorPaste {
    /// CSV or semicolon-separated text that is unmistakably a table becomes tab-separated rows; anything else is unchanged.
    public static func normalize(_ text: String) -> String { (try? TableSyntax.tryNormalizePaste(text)) ?? text }
}
