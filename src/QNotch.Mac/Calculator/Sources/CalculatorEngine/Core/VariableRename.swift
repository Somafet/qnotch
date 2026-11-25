import Foundation

/// A UTF-16 range of sheet source.
struct SourceSpan: Hashable {
    let start: Int, length: Int
    var end: Int { start + length }
    init(_ start: Int, _ length: Int) { self.start = start; self.length = length }
}

/// Lexical rename of a sheet variable. A variable is a name defined by an assignment line; its definitions and
/// references are found outside headings, comments, quoted text, tags, raw command payloads and function definitions.
/// Multi-word names match greedily, so renaming `rent` leaves `monthly rent` alone.
enum VariableRename {
    enum Problem { case none, invalid, taken }

    /// The spelling written for a name: words separated by single spaces.
    static func normalize(_ name: String) -> String { SheetSyntax.normalizeName(name) }

    /// The variable at a caret (empty selection) or exactly covered by a selection, or nil.
    static func find(_ text: String, _ start: Int, _ length: Int, _ token: CancellationToken = .none) throws -> (name: String, span: SourceSpan)? {
        let source = text.units
        var start = start, length = length
        if start < 0 || length < 0 || start + length > source.count { return nil }
        if length > 0 {
            // Surrounding whitespace in a selection is not part of the name.
            while length > 0 && NetChar.isWhiteSpace(source[start]) { start += 1; length -= 1 }
            while length > 0 && NetChar.isWhiteSpace(source[start + length - 1]) { length -= 1 }
        }
        let names = try definedNames(source, token)
        if names.isEmpty { return nil }
        var lineStart = 0
        if start > 0 { var i = max(0, start - 1); while i >= 0 && source[i] != 0x0A { i -= 1 }; lineStart = i + 1 }
        var lineEnd = start + length; while lineEnd < source.count && source[lineEnd] != 0x0A { lineEnd += 1 }
        for (name, span) in try scan(source, lineStart, lineEnd, names, token) {
            if length == 0 ? span.start <= start && start <= span.end : span.start == start && span.length == length { return (name, span) }
        }
        return nil
    }
    /// Every definition and reference of `name`, in source order.
    static func occurrences(_ text: String, _ name: String, _ token: CancellationToken = .none) throws -> [SourceSpan] {
        let source = text.units
        let names = try definedNames(source, token)
        let target = SheetSyntax.normalizeName(name)
        if !names.contains(target) { return [] }
        return try scan(source, 0, source.count, names, token).filter { $0.name.equalsIgnoreCase(target) }.map(\.span)
    }
    /// Whether `newName` may replace `oldName` in this sheet.
    static func check(_ source: String, _ oldName: String, _ newName: String, _ token: CancellationToken = .none) throws -> Problem {
        let normalized = SheetSyntax.normalizeName(newName)
        if !SheetSyntax.validName(normalized) { return .invalid }
        if normalized.equalsIgnoreCase(SheetSyntax.normalizeName(oldName)) { return .none }
        return try definedNames(source.units, token).contains(normalized) ? .taken : .none
    }
    /// The source with every occurrence of `oldName` renamed, or nil when the rename is not allowed.
    static func apply(_ source: String, _ oldName: String, _ newName: String, _ token: CancellationToken = .none) throws -> String? {
        if try check(source, oldName, newName, token) != .none { return nil }
        let replacement = Array(SheetSyntax.normalizeName(newName).utf16)
        var text = source.units
        for span in try occurrences(source, oldName, token).reversed() { text.replaceSubrange(span.start..<span.end, with: replacement) }
        return text.string
    }
    private static func definedNames(_ source: [UInt16], _ token: CancellationToken) throws -> NetHashSet<String> {
        var names = NetHashSet<String>.ignoringCase()
        for (start, end) in lines(source, 0, source.count) {
            let line = source[start..<end]
            if !line.contains(0x3D) { continue }
            if let name = try SheetSyntax.scan(line.string, token).assignment { names.insert(name) }
        }
        return names
    }
    private static func lines(_ source: [UInt16], _ from: Int, _ to: Int) -> [(Int, Int)] {
        var result: [(Int, Int)] = []; var start = from
        while start <= to {
            var end = start; while end < to && source[end] != 0x0A { end += 1 }
            let trimmed = end > start && source[end - 1] == 0x0D ? end - 1 : end
            result.append((start, trimmed))
            start = end + 1
        }
        return result
    }
    private static func scan(_ source: [UInt16], _ from: Int, _ to: Int, _ names: NetHashSet<String>, _ token: CancellationToken) throws -> [(name: String, span: SourceSpan)] {
        var found: [(String, SourceSpan)] = []
        let maxWords = names.map { $0.utf16.filter { $0 == 0x20 }.count + 1 }.max() ?? 1
        for (start, end) in lines(source, from, to) {
            try token.throwIfCancellationRequested()
            let line = Array(source[start..<end])
            let trimmed = line.string.netTrimStart
            if trimmed.isEmpty || trimmed == "#" || trimmed.hasPrefix("# ") { continue }
            if line.contains(0x3D) { let scanned = try SheetSyntax.scan(line.string, token); if scanned.directive != nil || scanned.functionName != nil { continue } }
            let words = self.words(line)
            var w = 0
            while w < words.count {
                var matched = 0
                var k = min(maxWords, words.count - w)
                while k >= 1 && matched == 0 {
                    defer { k -= 1 }
                    if !chained(line, words, w, k) { continue }
                    let candidate = words[w..<(w + k)].map { line.string($0.0, $0.1) }.joined(separator: " ")
                    if !names.contains(candidate) { continue }
                    found.append((SheetSyntax.normalizeName(candidate), SourceSpan(start + words[w].0, words[w + k - 1].1 - words[w].0)))
                    matched = k
                }
                w += max(1, matched)
            }
        }
        return found
    }
    // Words of a multi-word name are separated by whitespace only.
    private static func chained(_ line: [UInt16], _ words: [(Int, Int)], _ first: Int, _ count: Int) -> Bool {
        for i in (first + 1)..<(first + count) where i > first {
            for c in words[i - 1].1..<words[i].0 where !NetChar.isWhiteSpace(line[c]) { return false }
        }
        return true
    }
    private static func wordPart(_ c: UInt16) -> Bool { NetChar.isLetterOrDigit(c) || c == 0x5F || KeywordCatalog.isMark(c) }
    private static func words(_ line: [UInt16]) -> [(Int, Int)] {
        var words: [(Int, Int)] = []
        let raw = TextSyntax.rawPayloadStart(line.string)
        let limit = raw >= 0 ? raw : line.count
        var i = 0
        while i < limit {
            let c = line[i]
            if c == 0x2F && i + 1 < limit && line[i + 1] == 0x2F { break }
            if c == 0x22 {
                i += 1
                while i < limit && line[i] != 0x22 { if line[i] == 0x5C { i += 1 }; i += 1 }
                i += 1; continue
            }
            if c == 0x23 {
                let colour = DeveloperSyntax.colourLiteralLength(line, i)
                if colour > 0 { i += colour; continue }
                i += 1
                while i < limit && (wordPart(line[i]) || line[i] == 0x2D) { i += 1 }
                continue
            }
            if NetChar.isDigit(c) { while i < limit && (NetChar.isDigit(line[i]) || line[i] == 0x2E || line[i] == 0x5F) { i += 1 }; continue }
            if NetChar.isLetter(c) || c == 0x5F {
                let start = i
                while i < limit && wordPart(line[i]) { i += 1 }
                words.append((start, i)); continue
            }
            i += 1
        }
        return words
    }
}
