import Foundation

/// Exact Unicode scalar text. Preview, raw clipboard text and a reusable expression are separate.
final class TextValue: Hashable {
    static let maximumLength = 32768
    let value: String
    let display: String
    var copiesExpression: Bool { value.utf16.contains(0) }
    var copyText: String { copiesExpression ? expressionText : value }
    var expressionText: String { "text(" + TextValue.quote(value) + ")" }
    init(_ value: String) throws {
        try TextValue.validate(value); self.value = value
        var preview = value.units
        if preview.count > 96 {
            var left = 64; if NetChar.isHighSurrogate(preview[left - 1]) { left -= 1 }
            var right = preview.count - 24; if NetChar.isLowSurrogate(preview[right]) { right += 1 }
            preview = Array(preview[..<left]) + Array("…".utf16) + Array(preview[right...])
        }
        var shown = ""; var shownLength = 0
        for scalar in String(units: preview).unicodeScalars {
            let n = Int(scalar.value)
            let part: String
            if n == 10 { part = "\\n" } else if n == 13 { part = "\\r" } else if n == 9 { part = "\\t" }
            else if n < 32 || (127...159).contains(n) || n == 0x2028 || n == 0x2029 || n == 0x200E || n == 0x200F || (0x202A...0x202E).contains(n) || (0x2066...0x2069).contains(n) {
                part = "\\u" + String(n, radix: 16, uppercase: true).netPadLeft(4, "0")
            } else { part = String(scalar) }
            if shownLength + part.netLength > 124 { shown += "…"; break }
            shown += part; shownLength += part.netLength
        }
        display = value.isEmpty ? "\"\"" : shown
    }
    static func validate(_ text: String) throws {
        let u = text.units
        if u.count > maximumLength { throw CalcError.arithmetic("Text exceeds 32768 UTF-16 code units") }
        var i = 0
        while i < u.count {
            if NetChar.isSurrogate(u[i]) {
                if !NetChar.isHighSurrogate(u[i]) || i + 1 == u.count || !NetChar.isLowSurrogate(u[i + 1]) { throw CalcError.format("Text contains an unpaired UTF-16 surrogate") }
                i += 1
            }
            i += 1
        }
    }
    static func quote(_ text: String) -> String { NetJSONText.quote(text) }
    static func == (a: TextValue, b: TextValue) -> Bool { a.value == b.value && a.display == b.display }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

struct TextTransformEvidence: Hashable {
    let operation: String, input: String, output: String
    let inputUtf8Bytes: Int, outputUtf8Bytes: Int
    let inputBytePreview: String, inputPreview: String
}

final class TextLiteralExpression: Expression { let value: String; init(_ value: String) { self.value = value } }

enum TextSyntax {
    private static let commands: [(command: String, function: String)] = [("chmod", "chmod"), ("unicode", "unicode"), ("decode base64", "decodeBase64"), ("base64", "base64"), ("urlencode", "urlencode"), ("urldecode", "urldecode"), ("sha256", "sha256"), ("sha1", "sha1"), ("md5", "md5")]
    static func readQuoted(_ source: [UInt16], _ index: inout Int, _ token: CancellationToken) throws -> String {
        if source[index] != 0x22 { index += 1; throw CalcError.format("Expected text quote") }
        index += 1
        var result: [UInt16] = []; let start = index
        while index < source.count {
            if index & 255 == 0 { try token.throwIfCancellationRequested() }
            if index - start > TextValue.maximumLength * 6 { throw CalcError.arithmetic("Text literal length limit exceeded") }
            let c = source[index]; index += 1
            if c == 0x22 { let value = String(units: result); try TextValue.validate(value); return value }
            if c < 32 { throw CalcError.format("Escape control characters inside a text literal") }
            if c != 0x5C { result.append(c) }
            else {
                if index == source.count { throw CalcError.format("Unclosed text escape") }
                let escape = source[index]; index += 1
                if escape == 0x75 {
                    if index + 4 > source.count { throw CalcError.format("Incomplete Unicode escape") }
                    var value = 0
                    for _ in 0..<4 {
                        let h = source[index]; index += 1
                        if !NetChar.isAsciiHexDigit(h) { throw CalcError.format("Invalid Unicode escape") }
                        value = value * 16 + (h <= 0x39 ? Int(h) - 48 : Int(NetChar.upper(h)) - 65 + 10)
                    }
                    result.append(UInt16(value))
                } else {
                    switch escape {
                    case 0x22: result.append(0x22)
                    case 0x5C: result.append(0x5C)
                    case 0x2F: result.append(0x2F)
                    case 0x62: result.append(0x08)
                    case 0x66: result.append(0x0C)
                    case 0x6E: result.append(0x0A)
                    case 0x72: result.append(0x0D)
                    case 0x74: result.append(0x09)
                    default: throw CalcError.format("Invalid text escape")
                    }
                }
            }
            if result.count > TextValue.maximumLength { throw CalcError.arithmetic("Text exceeds 32768 UTF-16 code units") }
        }
        throw CalcError.format("Unclosed text literal")
    }
    static func readQuoted(_ source: String, _ index: inout Int, _ token: CancellationToken) throws -> String { try readQuoted(source.units, &index, token) }
    static func dataCallAt(_ source: [UInt16], _ open: Int) -> Bool {
        var end = open; while end > 0 && NetChar.isWhiteSpace(source[end - 1]) { end -= 1 }
        var start = end; while start > 0 && (NetChar.isLetterOrDigit(source[start - 1]) || source[start - 1] == 0x5F) { start -= 1 }
        guard end > start && end - start <= 128 else { return false }
        let name = source.string(start, end)
        return TextArithmetic.isFunction(name) || TableArithmetic.isFunction(name) || DeveloperArithmetic.isTextFunction(name) || name.equalsIgnoreCase("uuid")
    }
    static func attemptedDefinitionName(_ source: String) -> String? {
        let equal = assignmentIndex(source); if equal < 0 { return nil }
        let header = source.netSubstring(0, equal).netTrim; let open = header.netIndexOf("(")
        guard open > 0, header.hasSuffix(")") else { return nil }
        let name = header.netSubstring(0, open).netTrim
        return FunctionLibrary.validIdentifier(name, 64) ? name : nil
    }
    static func assignmentIndex(_ source: String) -> Int {
        let u = source.units
        if !u.contains(0x3D) { return -1 }
        var quoted = false; var i = 0
        while i < u.count {
            if quoted && u[i] == 0x5C { i += 2; continue }
            if u[i] == 0x22 { quoted.toggle() } else if !quoted && u[i] == 0x3D { return i }
            i += 1
        }
        return -1
    }
    private static func findNatural(_ text: String) -> (start: Int, payload: Int, function: String)? {
        let source = text.units
        func at(_ start: Int) -> (Int, Int, String)? {
            var start = start
            while start < source.count && NetChar.isWhiteSpace(source[start]) { start += 1 }
            if start == source.count || !NetChar.isLetter(source[start]) { return nil }
            for (command, function) in commands {
                var cursor = start; var matched = true
                for c in command.utf16 {
                    if c == 0x20 {
                        if cursor >= source.count || !NetChar.isWhiteSpace(source[cursor]) { matched = false; break }
                        while cursor < source.count && NetChar.isWhiteSpace(source[cursor]) { cursor += 1 }
                    } else {
                        if cursor >= source.count { matched = false; break }
                        let x = source[cursor]; cursor += 1
                        if NetChar.upper(x) != NetChar.upper(c) { matched = false; break }
                    }
                }
                if !matched || cursor == source.count || !NetChar.isWhiteSpace(source[cursor]) { continue }
                while cursor < source.count && NetChar.isWhiteSpace(source[cursor]) { cursor += 1 }
                if cursor < source.count && source[cursor] != 0x3D && source[cursor] != 0x28 { return (start, cursor, function) }
            }
            return nil
        }
        if let whole = at(0) { return whole }
        let equal = assignmentIndex(text); if equal < 0 { return nil }
        guard let candidate = at(equal + 1) else { return nil }
        let header = text.netSubstring(0, equal).netTrim; let open = header.netIndexOf("(")
        let plausible = open >= 0 ? header.hasSuffix(")") && FunctionLibrary.validIdentifier(header.netSubstring(0, open).netTrim, 64) :
            header.netLength > 0 && header.netLength <= 128 && header.netSplit(" ").filter { !$0.isEmpty }.allSatisfy { FunctionLibrary.validIdentifier($0, 128) }
        return plausible ? candidate : nil
    }
    /// Bounded lexical aid for source highlighting; returns the start of unquoted literal command data.
    static func rawPayloadStart(_ source: String) -> Int {
        if source.netLength > 4096 { return -1 }
        guard let command = findNatural(source) else { return -1 }
        return source.unit(at: command.payload) != 0x22 ? command.payload : -1
    }
    static func normalizeNatural(_ source: String, _ token: CancellationToken) throws -> String {
        try token.throwIfCancellationRequested()
        guard let (start, payload, function) = findNatural(source) else { return source }
        let u = source.units
        if u[payload] == 0x22 {
            var end = payload; _ = try readQuoted(u, &end, token)
            return u.string(0, start) + function + "(" + u.string(payload, end) + ")" + u.string(from: end)
        }
        let value = u.string(from: payload).netTrim; try TextValue.validate(value)
        return u.string(0, start) + function + "(" + TextValue.quote(value) + ")"
    }
}
