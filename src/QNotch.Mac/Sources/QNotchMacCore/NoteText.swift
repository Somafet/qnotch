import Foundation

/// Pure helpers for the Note module (Windows NoteModule): word count and line search.
public enum NoteText {
    public static let maxLength = 100_000

    public static func words(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// Each line containing `query` (case and diacritic insensitive), trimmed to a short snippet
    /// around the first match.
    public static func matches(of query: String, in text: String, limit: Int = 5, snippet: Int = 60) -> [String] {
        guard !query.isEmpty else { return [] }
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) where result.count < limit {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            if line.count <= snippet { result.append(line); continue }
            let start = line.index(range.lowerBound, offsetBy: -min(20, line.distance(from: line.startIndex, to: range.lowerBound)))
            let end = line.index(start, offsetBy: snippet, limitedBy: line.endIndex) ?? line.endIndex
            result.append((start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : ""))
        }
        return result
    }
}
