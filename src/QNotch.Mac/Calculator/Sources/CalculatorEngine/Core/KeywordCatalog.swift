import Foundation

enum KeywordRole: String, CaseIterable { case of = "Of", sum = "Sum", average = "Average", double = "Double", half = "Half", to = "To", nearest = "Nearest", decimals = "Decimals", significant = "Significant", leadingDecimals = "LeadingDecimals", leadingSignificant = "LeadingSignificant", digits = "Digits", roundEnd = "RoundEnd", postfixDouble = "PostfixDouble", postfixHalf = "PostfixHalf" }

/// Bounded embedded syntax data. Keywords are matched only in their grammatical role; source names are never rewritten.
enum KeywordCatalog {
    private struct Tables {
        var aliases: [KeywordRole: [String: [[String]]]] = [:]
        var cjkLexemes: [UInt16: [String]] = [:]
    }
    private static let tables: Tables = {
        do { return try load() } catch { fatalError("Invalid keyword catalog: \(error)") }
    }()
    private static func load() throws -> Tables {
        let root = try JSONNode.parse(CalculatorEngine.resource("LanguageKeywords.json"))
        var roles = NetDictionary<KeywordRole, NetHashSet<String>>(); var unspaced = NetHashSet<String>()
        let languages = try root.property("languages").arrayItems()
        if languages.count != 9 { throw CalcError.invalidData("Expected nine syntax languages") }
        for language in languages {
            for (name, value) in try language.property("keywords").objectProperties() {
                guard let key = KeywordRole(rawValue: name) else { throw CalcError.argument("Requested value '\(name)' was not found.") }
                var values = roles[key] ?? NetHashSet<String>()
                for item in try value.arrayItems() {
                    let text = normalize(try item.string())
                    if text.isEmpty || text.netLength > 64 || text.netSplit(" ").count > 8 { throw CalcError.invalidData("Invalid keyword alias") }
                    values.insert(text)
                    if try language.property("unspaced").bool() {
                        for word in text.netSplit(" ") where word.utf16.contains(where: { $0 > 127 }) { unspaced.insert(word) }
                    }
                }
                roles.set(key, values)
            }
        }
        if roles.values.reduce(0, { $0 + $1.count }) > 256 { throw CalcError.invalidData("Keyword catalog limit exceeded") }
        var t = Tables()
        for (role, values) in roles {
            let ordered = values.elements.stableSorted { a, b in
                let wa = a.netSplit(" ").count, wb = b.netSplit(" ").count
                return wa != wb ? wa > wb : a.netLength > b.netLength
            }
            var groups: [String: [[String]]] = [:]
            for text in ordered { let words = text.netSplit(" "); groups[words[0], default: []].append(words) }
            t.aliases[role] = groups
        }
        for word in unspaced { t.cjkLexemes[word.utf16.first!, default: []].append(word) }
        for (k, v) in t.cjkLexemes { t.cjkLexemes[k] = v.stableSorted { $0.netLength > $1.netLength } }
        return t
    }
    private static func normalize(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.netUpper }
    static func match(_ tokens: [Token], _ position: Int, _ role: KeywordRole) -> Int {
        guard position < tokens.count, tokens[position].kind == .name, let words = tables.aliases[role],
              let candidates = words[normalize(tokens[position].text)] else { return 0 }
        for alias in candidates {
            if position + alias.count > tokens.count { continue }
            var found = true
            for index in 0..<alias.count where normalize(tokens[position + index].text) != alias[index] { found = false; break }
            if found { return alias.count }
        }
        return 0
    }
    static func isOf(_ text: String) -> Bool { tables.aliases[.of]![normalize(text)] != nil }
    static func isMark(_ value: UInt16) -> Bool {
        switch NetChar.category(value) { case .nonspacingMark?, .spacingMark?: return true; default: return false }
    }
    static func cjkTokenLength(_ source: [UInt16], _ start: Int, _ knownNames: NetHashSet<String>?) -> Int {
        guard let candidates = tables.cjkLexemes[source[start]] else { return 0 }
        func identifierChar(_ c: UInt16) -> Bool { NetChar.isLetterOrDigit(c) || c == 0x5F || isMark(c) }
        // Bound lookahead, and protect complete declared identifiers and all call names.
        var identifierEnd = start
        while identifierEnd < source.count && identifierEnd - start <= 128 && identifierChar(source[identifierEnd]) { identifierEnd += 1 }
        if identifierEnd - start <= 128 {
            if knownNames?.contains(source.string(start, identifierEnd)) == true { return 0 }
            var afterName = identifierEnd
            while afterName < source.count && NetChar.isWhiteSpace(source[afterName]) { afterName += 1 }
            if afterName < source.count && source[afterName] == 0x28 { return 0 }
        }
        func knownOperandFollows(_ position: Int) -> Bool {
            guard let knownNames else { return false }
            var end = position
            while end < source.count && end - position <= 128 && identifierChar(source[end]) { end += 1 }
            return end - position <= 128 && knownNames.contains(source.string(position, end))
        }
        for candidate in candidates {
            let c = candidate.units
            guard start + c.count <= source.count, Array(source[start..<(start + c.count)]) == c else { continue }
            let end = start + c.count
            if end == source.count || !NetChar.isLetter(source[end]) || tables.cjkLexemes[source[end]] != nil || knownOperandFollows(end) { return c.count }
        }
        return 0
    }
}

enum NumberLanguage {
    static func cjkExponent(_ text: String) -> Int {
        switch text { case "万", "만": return 4; case "億", "亿", "억": return 8; default: return 0 }
    }
    static func isCjkScale(_ value: UInt16) -> Bool { [0x4E07, 0x5104, 0x4EBF, 0xB9CC, 0xC5B5].contains(value) }
    static func isShortSuffix(_ text: String) -> Bool { ["k", "K", "M", "B"].contains(text) }
    static func tryMultiplier(_ text: String, _ attached: Bool) -> Rational? {
        var exponent = cjkExponent(text)
        if exponent == 0 && attached { switch text { case "k", "K": exponent = 3; case "M": exponent = 6; case "B": exponent = 9; default: break } }
        if exponent == 0 {
            switch text.netLower {
            case "thousand", "thousands": exponent = 3
            case "million", "millions": exponent = 6
            case "billion", "billions": exponent = 9
            default: break
            }
        }
        return exponent == 0 ? nil : try! Rational(BigInt.pow(10, exponent))
    }
    static func canonicalToken(_ tokens: [Token], _ index: Int) -> String {
        let token = tokens[index]; let text = token.text.netUpper
        if token.kind == .date { return "@DATE:" + text }
        if token.kind == .time { return "@TIME:" + text }
        if token.kind == .zone { return "@ZONE:" + token.text }
        if index > 0 && token.joinedToPrevious && (token.text == "+" || token.text == "-") && index + 1 < tokens.count && tokens[index + 1].kind == .time {
            return "@ADJACENT:" + token.text
        }
        if index > 0 && token.joinedToPrevious {
            let previous = tokens[index - 1]
            // Preserve old canonical hashes except where newly supported syntax gives whitespace a meaning.
            if previous.kind == .number && token.kind == .name && isShortSuffix(token.text) { return "@SCALE:" + text }
            if previous.kind == .name && cjkExponent(previous.text) != 0 && token.kind == .number { return "@GROUP:" + text }
        }
        return text
    }
}
