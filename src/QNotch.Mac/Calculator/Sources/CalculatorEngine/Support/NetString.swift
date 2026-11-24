import Foundation

// C# strings are sequences of UTF-16 code units, and the C# engine indexes, measures and classifies
// them unit by unit. The port keeps that contract: lengths, indices and limits below are UTF-16 based,
// and character tests follow .NET (InvariantCulture) rather than Swift's grapheme semantics.

typealias UTF16Unit = UInt16

extension UInt16 {
    @inline(__always) init(ascii c: Unicode.Scalar) { self = UInt16(c.value) }
}

/// char.* classification and invariant casing on one UTF-16 code unit, as .NET does it.
enum NetChar {
    @inline(__always) static func scalar(_ c: UInt16) -> Unicode.Scalar? { Unicode.Scalar(UInt32(c)) }
    static func category(_ c: UInt16) -> Unicode.GeneralCategory? {
        if c >= 0xD800 && c <= 0xDFFF { return nil } // UnicodeCategory.Surrogate
        return scalar(c)?.properties.generalCategory
    }
    @inline(__always) static func isAsciiDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) static func isAsciiLetter(_ c: UInt16) -> Bool { (c | 0x20) >= 97 && (c | 0x20) <= 122 }
    @inline(__always) static func isAsciiLetterOrDigit(_ c: UInt16) -> Bool { isAsciiDigit(c) || isAsciiLetter(c) }
    @inline(__always) static func isAsciiHexDigit(_ c: UInt16) -> Bool { isAsciiDigit(c) || ((c | 0x20) >= 97 && (c | 0x20) <= 102) }
    static func isLetter(_ c: UInt16) -> Bool {
        if c < 128 { return isAsciiLetter(c) }
        switch category(c) {
        case .uppercaseLetter?, .lowercaseLetter?, .titlecaseLetter?, .modifierLetter?, .otherLetter?: return true
        default: return false
        }
    }
    /// char.IsDigit: decimal digits (Nd) in any script.
    static func isDigit(_ c: UInt16) -> Bool { c < 128 ? isAsciiDigit(c) : category(c) == .decimalNumber }
    static func isLetterOrDigit(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) }
    static func isUpper(_ c: UInt16) -> Bool { c < 128 ? (c >= 65 && c <= 90) : category(c) == .uppercaseLetter }
    static func isLower(_ c: UInt16) -> Bool { c < 128 ? (c >= 97 && c <= 122) : category(c) == .lowercaseLetter }
    static func isPunctuation(_ c: UInt16) -> Bool {
        switch category(c) {
        case .connectorPunctuation?, .dashPunctuation?, .openPunctuation?, .closePunctuation?, .initialPunctuation?, .finalPunctuation?, .otherPunctuation?: return true
        default: return false
        }
    }
    static func isSymbol(_ c: UInt16) -> Bool {
        switch category(c) { case .mathSymbol?, .currencySymbol?, .modifierSymbol?, .otherSymbol?: return true; default: return false }
    }
    static func isControl(_ c: UInt16) -> Bool { c < 0x20 || (c >= 0x7F && c <= 0x9F) }
    static func isSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDFFF }
    static func isHighSurrogate(_ c: UInt16) -> Bool { c >= 0xD800 && c <= 0xDBFF }
    static func isLowSurrogate(_ c: UInt16) -> Bool { c >= 0xDC00 && c <= 0xDFFF }
    /// char.IsWhiteSpace.
    static func isWhiteSpace(_ c: UInt16) -> Bool {
        if c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x85 { return true }
        if c < 0x1680 { return false }
        switch category(c) { case .spaceSeparator?, .lineSeparator?, .paragraphSeparator?: return true; default: return false }
    }
    /// char.ToUpperInvariant: the simple (one-to-one) uppercase mapping.
    static func upper(_ c: UInt16) -> UInt16 {
        if c < 128 { return (c >= 97 && c <= 122) ? c - 32 : c }
        if isSurrogate(c) { return c }
        if c == 0x0131 { return 0x49 } // dotless i
        guard let s = scalar(c) else { return c }
        let mapped = s.properties.uppercaseMapping.unicodeScalars
        if mapped.count == 1, let m = mapped.first, m.value <= 0xFFFF { return UInt16(m.value) }
        return c
    }
    /// char.ToLowerInvariant: the simple (one-to-one) lowercase mapping.
    static func lower(_ c: UInt16) -> UInt16 {
        if c < 128 { return (c >= 65 && c <= 90) ? c + 32 : c }
        if isSurrogate(c) { return c }
        if c == 0x0130 { return 0x69 } // İ → i
        guard let s = scalar(c) else { return c }
        let mapped = s.properties.lowercaseMapping.unicodeScalars
        if mapped.count == 1, let m = mapped.first, m.value <= 0xFFFF { return UInt16(m.value) }
        return c
    }
}

extension String {
    /// C# `string.Length`.
    @inline(__always) var netLength: Int { utf16.count }
    /// The UTF-16 code units.
    @inline(__always) var units: [UInt16] { Array(utf16) }
    init<S: Sequence>(units: S) where S.Element == UInt16 { self = String(decoding: Array(units), as: UTF16.self) }
    init(unit: UInt16) { self = String(decoding: [unit], as: UTF16.self) }

    /// C# `text[i]`.
    func unit(at offset: Int) -> UInt16 { utf16[utf16.index(utf16.startIndex, offsetBy: offset)] }
    /// C# `text.Substring(start)` / `text[start..]`.
    func netSubstring(_ start: Int) -> String { String(units: utf16.dropFirst(start)) }
    /// C# `text.Substring(start, length)` / `text[start..(start + length)]`.
    func netSubstring(_ start: Int, _ length: Int) -> String { String(units: utf16.dropFirst(start).prefix(length)) }
    /// C# `text[start..end]`.
    func netSlice(_ start: Int, _ end: Int) -> String { netSubstring(start, end - start) }

    /// ToUpperInvariant / ToLowerInvariant: per code unit simple mappings.
    var netUpper: String {
        if utf8.allSatisfy({ $0 < 128 }) { return uppercased() }
        return String(units: utf16.map(NetChar.upper))
    }
    var netLower: String {
        if utf8.allSatisfy({ $0 < 128 }) { return lowercased() }
        return String(units: utf16.map(NetChar.lower))
    }
    /// StringComparison.OrdinalIgnoreCase equality.
    func equalsIgnoreCase(_ other: String) -> Bool {
        if self == other { return true }
        let a = utf16, b = other.utf16
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { $0 == $1 || NetChar.upper($0) == NetChar.upper($1) }
    }
    func startsWithIgnoreCase(_ prefix: String) -> Bool {
        let a = utf16, b = prefix.utf16
        guard a.count >= b.count else { return false }
        return zip(a, b).allSatisfy { $0 == $1 || NetChar.upper($0) == NetChar.upper($1) }
    }
    func endsWithIgnoreCase(_ suffix: String) -> Bool {
        let a = Array(utf16), b = Array(suffix.utf16)
        guard a.count >= b.count else { return false }
        return zip(a[(a.count - b.count)...], b).allSatisfy { $0 == $1 || NetChar.upper($0) == NetChar.upper($1) }
    }
    /// The key C# OrdinalIgnoreCase hashing compares by.
    var ordinalKey: String { netUpper }
    /// string.Trim(): removes char.IsWhiteSpace code units from both ends.
    var netTrim: String {
        let u = Array(utf16)
        var start = 0, end = u.count
        while start < end && NetChar.isWhiteSpace(u[start]) { start += 1 }
        while end > start && NetChar.isWhiteSpace(u[end - 1]) { end -= 1 }
        if start == 0 && end == u.count { return self }
        return String(units: u[start..<end])
    }
    var netTrimStart: String {
        let u = Array(utf16); var start = 0
        while start < u.count && NetChar.isWhiteSpace(u[start]) { start += 1 }
        return start == 0 ? self : String(units: u[start...])
    }
    var netTrimEnd: String {
        let u = Array(utf16); var end = u.count
        while end > 0 && NetChar.isWhiteSpace(u[end - 1]) { end -= 1 }
        return end == u.count ? self : String(units: u[..<end])
    }
    func netTrim(_ chars: Character...) -> String { netTrimStart(chars).netTrimEnd(chars) }
    func netTrimStart(_ chars: [Character]) -> String {
        let set = Set(chars.flatMap { $0.utf16 }); let u = Array(utf16); var start = 0
        while start < u.count && set.contains(u[start]) { start += 1 }
        return String(units: u[start...])
    }
    func netTrimEnd(_ chars: [Character]) -> String {
        let set = Set(chars.flatMap { $0.utf16 }); let u = Array(utf16); var end = u.count
        while end > 0 && set.contains(u[end - 1]) { end -= 1 }
        return String(units: u[..<end])
    }
    func netTrimStart(_ chars: Character...) -> String { netTrimStart(chars) }
    func netTrimEnd(_ chars: Character...) -> String { netTrimEnd(chars) }
    /// string.IndexOf(char) / IndexOf(string, StringComparison.Ordinal), in UTF-16 units; -1 when absent.
    func netIndexOf(_ unit: UInt16, from start: Int = 0) -> Int {
        var i = 0
        for c in utf16 { if i >= start && c == unit { return i }; i += 1 }
        return -1
    }
    func netIndexOf(_ c: Character, from start: Int = 0) -> Int { netIndexOf(c.utf16.first!, from: start) }
    func netIndexOf(_ needle: String, from start: Int = 0) -> Int {
        let h = Array(utf16), n = Array(needle.utf16)
        if n.isEmpty { return start <= h.count ? start : -1 }
        if h.count < n.count { return -1 }
        var i = start
        while i <= h.count - n.count {
            if h[i] == n[0] && Array(h[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return -1
    }
    func netLastIndexOf(_ c: Character) -> Int {
        let u = Array(utf16), t = c.utf16.first!
        var i = u.count - 1
        while i >= 0 { if u[i] == t { return i }; i -= 1 }
        return -1
    }
    func netContains(_ c: Character) -> Bool { netIndexOf(c) >= 0 }
    /// string.Split(char) keeping empty entries.
    func netSplit(_ separator: Character) -> [String] {
        let s = separator.utf16.first!
        return Array(utf16).split(separator: s, omittingEmptySubsequences: false).map { String(units: $0) }
    }
    /// string.Split(string) keeping empty entries.
    func netSplit(_ separator: String) -> [String] {
        let sep = Array(separator.utf16)
        if sep.isEmpty { return [self] }
        let u = Array(utf16); var result: [String] = []; var start = 0; var i = 0
        while i + sep.count <= u.count {
            if u[i] == sep[0] && Array(u[i..<(i + sep.count)]) == sep { result.append(String(units: u[start..<i])); i += sep.count; start = i } else { i += 1 }
        }
        result.append(String(units: u[start...]))
        return result
    }
    /// string.Split((char[])null, StringSplitOptions.RemoveEmptyEntries): split on white space.
    var netSplitWhiteSpace: [String] {
        Array(utf16).split(whereSeparator: NetChar.isWhiteSpace).map { String(units: $0) }
    }
    /// string.Replace(old, new), ordinal.
    func netReplace(_ old: String, _ new: String) -> String { replacingOccurrences(of: old, with: new, options: .literal) }
    /// PadLeft / PadRight by UTF-16 length.
    func netPadLeft(_ width: Int, _ pad: Character = " ") -> String {
        let n = netLength; return n >= width ? self : String(repeating: pad, count: width - n) + self
    }
    func netPadRight(_ width: Int, _ pad: Character = " ") -> String {
        let n = netLength; return n >= width ? self : self + String(repeating: pad, count: width - n)
    }
    /// string.Insert(index, value).
    func netInsert(_ index: Int, _ value: String) -> String { netSubstring(0, index) + value + netSubstring(index) }
    /// string.Remove(start, count).
    func netRemove(_ start: Int, _ count: Int) -> String { netSubstring(0, start) + netSubstring(start + count) }
    /// string.Remove(start).
    func netRemove(_ start: Int) -> String { netSubstring(0, start) }
    /// The number of Unicode scalars (C# Rune count / EnumerateRunes).
    var runeCount: Int { unicodeScalars.count }
    /// StringComparer.Ordinal comparison (UTF-16 code unit order).
    static func ordinalCompare(_ a: String, _ b: String) -> Int {
        var i = a.utf16.makeIterator(), j = b.utf16.makeIterator()
        while true {
            switch (i.next(), j.next()) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (x?, y?): if x != y { return Int(x) - Int(y) }
            }
        }
    }
    /// StringComparer.OrdinalIgnoreCase comparison.
    static func ordinalIgnoreCaseCompare(_ a: String, _ b: String) -> Int { ordinalCompare(a.ordinalKey, b.ordinalKey) }
}

extension ArraySlice where Element == UInt16 {
    var string: String { String(units: self) }
}

extension Array where Element == UInt16 {
    /// `source[start..end]` as a string.
    func string(_ start: Int, _ end: Int) -> String { String(units: self[start..<end]) }
    func string(from start: Int) -> String { String(units: self[start...]) }
    var string: String { String(units: self) }
    /// C# `text.Contains(c)`.
    func contains(ascii c: Unicode.Scalar) -> Bool { contains(UInt16(c.value)) }
}

/// Small sequence helpers for LINQ calls whose semantics differ from the obvious Swift spelling.
extension Sequence {
    /// LINQ OrderBy/ThenBy: a stable sort.
    func stableSorted(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> [Element] {
        var indexed = Array(enumerated())
        try indexed.sort { a, b in
            if try areInIncreasingOrder(a.element, b.element) { return true }
            if try areInIncreasingOrder(b.element, a.element) { return false }
            return a.offset < b.offset
        }
        return indexed.map(\.element)
    }
}
