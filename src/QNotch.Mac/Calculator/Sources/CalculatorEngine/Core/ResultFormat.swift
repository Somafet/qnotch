import Foundation

/// The host's regional number format (C# CultureInfo.NumberFormat): its decimal and group separators.
struct RegionalNumberFormat: Hashable {
    let decimalSeparator: String
    let groupSeparator: String
    static let invariant = RegionalNumberFormat(decimalSeparator: ".", groupSeparator: ",")
    init(decimalSeparator: String, groupSeparator: String) { self.decimalSeparator = decimalSeparator; self.groupSeparator = groupSeparator }
    init(_ locale: Locale) { self.init(decimalSeparator: locale.decimalSeparator ?? ".", groupSeparator: locale.groupingSeparator ?? ",") }
}

/// Digit grouping and decimal separator for displayed results. Source input stays invariant.
struct NumberStyle: Hashable {
    /// Narrow no-break space: a grouping space never wraps a value across lines.
    static let space = "\u{202F}"
    static let plain = try! NumberStyle("", ".")
    static let presetIds = ["plain", "system", "comma", "period", "space", "apostrophe"]
    let groupSeparator: String
    let decimalSeparator: Character
    init(_ groupSeparator: String, _ decimalSeparator: Character) throws {
        if decimalSeparator != "." && decimalSeparator != "," { throw CalcError.argument("Unsupported decimal separator") }
        if !["", ",", ".", "'", NumberStyle.space].contains(groupSeparator) { throw CalcError.argument("Unsupported group separator") }
        if groupSeparator.count == 1 && groupSeparator.first == decimalSeparator { throw CalcError.argument("Group and decimal separators must differ") }
        self.groupSeparator = groupSeparator; self.decimalSeparator = decimalSeparator
    }
    /// Resolves a stored preset. "system" reads the regional format the host supplies.
    static func fromId(_ id: String?, _ regional: RegionalNumberFormat) throws -> NumberStyle {
        switch id {
        case nil, "plain"?: return plain
        case "system"?: return try fromRegional(regional)
        case "comma"?: return try NumberStyle(",", ".")
        case "period"?: return try NumberStyle(".", ",")
        case "space"?: return try NumberStyle(space, ",")
        case "apostrophe"?: return try NumberStyle("'", ".")
        default: throw CalcError.argument("Unsupported number style")
        }
    }
    /// Maps a regional format onto the supported separators; anything else keeps the invariant form.
    static func fromRegional(_ format: RegionalNumberFormat) throws -> NumberStyle {
        let decimalSeparator: Character = format.decimalSeparator == "," ? "," : "."
        var group: String
        switch format.groupSeparator {
        case ",": group = ","
        case ".": group = "."
        case "'", "\u{2019}": group = "'"
        case " ", "\u{00A0}", "\u{202F}", "\u{2009}": group = space
        default: group = ""
        }
        if group.count == 1 && group.first == decimalSeparator { group = "" }
        return try NumberStyle(group, decimalSeparator)
    }
    /// Compact example for settings, e.g. 1,234.56.
    var example: String { "1" + groupSeparator + "234" + String(decimalSeparator) + "56" }
}

/// Display-only result presentation. It never changes evaluation, copy text or saved source.
struct ResultFormat: Hashable {
    static let maxDecimalPlaces = 20
    static let `default` = ResultFormat()
    var decimalPlaces: Int?
    var style: NumberStyle?
    init(_ decimalPlaces: Int? = nil, _ style: NumberStyle? = nil) { self.decimalPlaces = decimalPlaces; self.style = style }
    var numberStyle: NumberStyle { style ?? .plain }
    var isDefault: Bool { decimalPlaces == nil && numberStyle == .plain }
}

/// Presents numeric and monetary results with a display preference. Structured values (dates, times,
/// addresses, codes, text, lists, matrices, tables) keep their canonical, reusable forms.
enum ResultFormatter {
    static func format(_ result: LineResult, _ format: ResultFormat) throws -> String {
        guard !result.isDeclaration, result.error == nil, let value = result.shown ?? result.value else { return result.display }
        return try self.format(value, format)
    }
    static func format(_ value: SheetValue, _ format: ResultFormat) throws -> String {
        if let places = format.decimalPlaces, places < 0 || places > ResultFormat.maxDecimalPlaces { throw CalcError.argument("Unsupported decimal places") }
        if format.isDefault { return try value.display }
        do {
            switch value {
            case .number(var number):
                if number.useCompoundDuration && number.unit?.dimension == TimeArithmetic.timeDimension { return try value.display }
                // A domain display precision (approximate conversions and roots) outranks the preference.
                if let places = format.decimalPlaces, number.displayDecimalPlaces == nil { number.displayDecimalPlaces = places }
                let suffix = number.isPercentage ? "%" : number.unit.map { " " + $0.symbol } ?? ""
                return separate(try number.display, suffix, format.numberStyle)
            case .money(let money):
                // Money already shows its currency's minor units; only separators change.
                return separate(try money.display, " " + money.currency + (money.magnitude.unit?.moneySuffix() ?? ""), format.numberStyle)
            default: return try value.display
            }
        } catch let error as CalcError where error.isArithmetic { return try value.display }
    }
    /// Rewrites separators in the magnitude only; the unit/currency suffix is left untouched.
    static func separate(_ text: String, _ suffix: String, _ style: NumberStyle) -> String {
        if style == .plain || !Array(text.utf16).ends(with: Array(suffix.utf16)) { return text }
        let body = Array(text.utf16.dropLast(suffix.utf16.count))
        var output = ""
        var i = 0
        while i < body.count {
            if !NetChar.isAsciiDigit(body[i]) { output += String(units: [body[i]]); i += 1; continue }
            // Canonical displays use commas only inside constant notation groups (299,792,458).
            let start = i; var integer: [UInt16] = []
            while i < body.count && (NetChar.isAsciiDigit(body[i]) || body[i] == 0x2C && i + 1 < body.count && NetChar.isAsciiDigit(body[i + 1])) {
                if body[i] != 0x2C { integer.append(body[i]) }
                i += 1
            }
            var fraction: String?
            if i + 1 < body.count && body[i] == 0x2E && NetChar.isAsciiDigit(body[i + 1]) {
                i += 1; let fractionStart = i
                while i < body.count && NetChar.isAsciiDigit(body[i]) { i += 1 }
                fraction = body.string(fractionStart, i)
            }
            let before: UInt16 = start > 0 ? body[start - 1] : 0
            let exponent = before == 0x65 || ((before == 0x2D || before == 0x2B) && start > 1 && body[start - 2] == 0x65)
            let radicand = start >= 5 && body.string(start - 5, start) == "sqrt("
            // A grouped numerator or denominator could read as a decimal: 1.234/7.
            let fractionPart = before == 0x2F || i < body.count && body[i] == 0x2F
            let digits = integer.string
            output += exponent || radicand || fractionPart ? digits : group(digits, style.groupSeparator)
            if let fraction { output += String(style.decimalSeparator) + fraction }
        }
        return output + suffix
    }
    private static func group(_ digits: String, _ separator: String) -> String {
        let d = Array(digits)
        if separator.isEmpty || d.count < 4 { return digits }
        let lead = d.count % 3 == 0 ? 3 : d.count % 3
        var text = String(d[0..<lead])
        var i = lead
        while i < d.count { text += separator + String(d[i..<(i + 3)]); i += 3 }
        return text
    }
}

extension Array where Element: Equatable {
    func ends(with suffix: [Element]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}
