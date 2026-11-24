import Foundation

final class ColourLiteralExpression: Expression { let text: String; init(_ text: String) { self.text = text } }

enum DeveloperSyntax {
    /// Recognize a hex colour only where an operand may begin; trailing #face stays a sheet tag.
    static func colourLiteralLength(_ source: [UInt16], _ start: Int) -> Int {
        if start < 0 || start >= source.count || source[start] != 0x23 { return 0 }
        var before = start - 1; while before >= 0 && NetChar.isWhiteSpace(source[before]) { before -= 1 }
        if before >= 0 && source[before] != 0x3D && source[before] != 0x28 && source[before] != 0x2C { return 0 }
        var end = start + 1; while end < source.count && end - start <= 9 && NetChar.isAsciiHexDigit(source[end]) { end += 1 }
        if end < source.count && (NetChar.isLetterOrDigit(source[end]) || source[end] == 0x5F || source[end] == 0x2D) { return 0 }
        return [3, 4, 6, 8].contains(end - start - 1) ? end - start : 0
    }
    static func colourLiteralLength(_ source: String, _ start: Int) -> Int { colourLiteralLength(source.units, start) }
    static func codepointLength(_ source: [UInt16], _ start: Int) -> Int {
        if start + 6 > source.count || NetChar.upper(source[start]) != 0x55 || source[start + 1] != 0x2B { return 0 }
        var end = start + 2; while end < source.count && NetChar.isAsciiHexDigit(source[end]) { end += 1 }
        let digits = end - start - 2
        if digits < 4 || digits > 6 || end < source.count && (NetChar.isLetterOrDigit(source[end]) || source[end] == 0x5F) { return 0 }
        return end - start
    }
    static func tryAspect(_ source: [UInt16], _ start: Int) -> (end: Int, dimensions: String)? {
        var i = start
        func number() -> String? {
            let first = i; var dots = 0, digits = 0
            while i < source.count && i - first <= 256 && (NetChar.isAsciiDigit(source[i]) || source[i] == 0x2E) { if source[i] == 0x2E { dots += 1 } else { digits += 1 }; i += 1 }
            return digits > 0 && dots <= 1 && i - first <= 256 ? source.string(first, i) : nil
        }
        guard let width = number() else { return nil }
        while i < source.count && NetChar.isWhiteSpace(source[i]) { i += 1 }
        if i == source.count || (source[i] != 0x78 && source[i] != 0xD7) { return nil }
        i += 1
        while i < source.count && NetChar.isWhiteSpace(source[i]) { i += 1 }
        guard let height = number() else { return nil }
        let space = i; while i < source.count && NetChar.isWhiteSpace(source[i]) { i += 1 }
        if i == space || i + 6 > source.count || !source.string(i, i + 6).equalsIgnoreCase("aspect") { return nil }
        i += 6; if i < source.count && (NetChar.isLetterOrDigit(source[i]) || source[i] == 0x5F) { return nil }
        return (i, width + "x" + height)
    }
}
