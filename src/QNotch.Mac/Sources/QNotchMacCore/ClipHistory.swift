import Foundation

/// Clipboard history rules, ported from Windows ClipProcessor and ClipboardState.
public enum ClipKind: String, Codable { case text, link, code, image }

public struct ClipEntry: Equatable, Identifiable {
    public let id: UUID
    public var kind: ClipKind
    /// Full text (text, link, code); nil for images.
    public var text: String?
    /// PNG bytes for images.
    public var png: Data?
    /// Dedupe key: the text, or an image hash.
    public var key: String
    public var preview: String
    /// One-line form for the Home card and search.
    public var line: String
    public var meta: String
    public var pinned = false
    public var created: Date

    public init(id: UUID = UUID(), kind: ClipKind, text: String?, png: Data? = nil, key: String, preview: String, line: String, meta: String, pinned: Bool = false, created: Date) {
        self.id = id; self.kind = kind; self.text = text; self.png = png; self.key = key
        self.preview = preview; self.line = line; self.meta = meta; self.pinned = pinned; self.created = created
    }

    public var imageBytes: Int { png?.count ?? 0 }
}

public enum ClipText {
    public static let maxTextLength = 200_000

    static let keywords: Set<String> = ["function", "def", "class", "import", "using", "namespace", "public", "private", "protected", "static",
        "const", "let", "var", "return", "package", "fn", "struct", "interface", "enum", "export", "async", "await", "#include", "#define",
        "SELECT", "INSERT", "CREATE", "<?php", "func", "guard"]
    static let control: Set<String> = ["if", "for", "while", "switch", "catch", "foreach"]

    public static func entry(_ text: String, at date: Date = Date()) -> ClipEntry? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, text.count <= maxTextLength else { return nil }
        let kind = classify(t)
        let preview: String, meta: String
        switch kind {
        case .link:
            preview = cut(t, 150)
            let host = URL(string: t.lowercased().hasPrefix("www.") ? "https://" + t : t)?.host
            meta = "Link" + (host.map { " · " + $0 } ?? "")
        case .code:
            let lines = t.components(separatedBy: "\n")
            preview = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 || !"{}();".contains($0) }
                .prefix(2).map { cut($0, 80) }.joined(separator: "\n")
            meta = "Code · \(lines.count) \(lines.count == 1 ? "line" : "lines")"
        default:
            preview = cut(collapse(t), 150)
            meta = "Text · \(t.count.formatted()) chars"
        }
        return ClipEntry(kind: kind, text: text, key: text, preview: preview, line: cut(preview.replacingOccurrences(of: "\n", with: " "), 60), meta: meta, created: date)
    }

    public static func classify(_ t: String) -> ClipKind {
        if t.count < 2048, !t.contains(where: { $0 == " " || $0.isNewline || $0 == "\t" }), isURL(t) { return .link }
        if let first = t.first, let last = t.last, t.count >= 2, (first == "{" && last == "}") || (first == "[" && last == "]"), t.contains("\":") { return .code }
        if t.count > 6, t.first == "<", t.last == ">", t.contains("</") || t.contains("/>") { return .code }
        var score = 0, indent = 0, lines = 0
        for raw in String(t.prefix(2000)).components(separatedBy: "\n") {
            let l = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            guard !l.isEmpty else { continue }
            lines += 1
            if l.hasPrefix("  ") || l.hasPrefix("\t") { indent += 1 }
            let tl = l.trimmingCharacters(in: .whitespaces)
            if let last = tl.last, ";{}".contains(last) { score += 1 }
            if ["//", "/*", "*/", "#!"].contains(where: tl.hasPrefix) { score += 1 }
            if ["=>", "->", "==", "!=", "();", "){"].contains(where: tl.contains) { score += 1 }
            let word = String(tl.prefix { $0.isLetter || $0.isNumber || "#_<?".contains($0) })
            let rest = tl.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if keywords.contains(word) || (control.contains(word) && rest.hasPrefix("(")) { score += 2 }
        }
        score += indent / 2
        return score >= 3 && score >= lines / 2 ? .code : .text
    }

    static func isURL(_ t: String) -> Bool {
        let lower = t.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || (lower.hasPrefix("www.") && t.count > 6)
            || lower.hasPrefix("mailto:") || lower.hasPrefix("file://")
    }

    static func cut(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func collapse(_ t: String) -> String {
        String(t.prefix(400)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : "\(max(1, bytes / 1024)) KB"
    }

    /// "Just now", "5m", "3h", "2d" ago.
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

/// Ordered history: pinned first, then newest. Caps entries and image bytes, never evicting pins.
public struct ClipHistory: Equatable {
    public static let limit = 40
    public static let imageBudget = 8 << 20
    public static let persistLimit = 20_000

    public private(set) var entries: [ClipEntry] = []
    public init(entries: [ClipEntry] = []) { self.entries = entries }

    /// Adds `entry`, or moves an identical one to the front of the unpinned entries with a fresh time.
    public mutating func add(_ entry: ClipEntry) {
        if let index = entries.firstIndex(where: { $0.key == entry.key && $0.kind == entry.kind }) {
            var existing = entries.remove(at: index)
            existing.created = entry.created
            insert(existing)
        } else {
            insert(entry)
        }
        trim()
    }

    private mutating func insert(_ entry: ClipEntry) {
        if entry.pinned { entries.insert(entry, at: 0); return }
        let firstUnpinned = entries.firstIndex { !$0.pinned } ?? entries.count
        entries.insert(entry, at: firstUnpinned)
    }

    private mutating func trim() {
        while entries.count > Self.limit, let index = entries.lastIndex(where: { !$0.pinned }) { entries.remove(at: index) }
        while entries.reduce(0, { $0 + $1.imageBytes }) > Self.imageBudget,
              let index = entries.lastIndex(where: { !$0.pinned && $0.kind == .image }) { entries.remove(at: index) }
    }

    public mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    public mutating func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.pinned.toggle()
        insert(entry)
    }

    /// Clears everything but the pinned entries.
    public mutating func clearUnpinned() { entries.removeAll { !$0.pinned } }

    /// Text entries that may be written to disk (images never are).
    public var persistable: [ClipEntry] { entries.filter { $0.kind != .image && ($0.text?.count ?? 0) <= Self.persistLimit } }

    public func search(_ query: String) -> [ClipEntry] {
        entries.filter { $0.kind != .image && ($0.text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil) }
    }
}

public struct ClipboardSettings: Codable, Equatable {
    public var keepHistory = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case keepHistory }
    public init(from decoder: Decoder) throws { keepHistory = try decoder.container(keyedBy: CodingKeys.self).value(.keepHistory, false) }
}
