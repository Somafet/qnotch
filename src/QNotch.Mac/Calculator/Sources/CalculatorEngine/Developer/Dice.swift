import Foundation

enum DiceSelection: Hashable { case all, keepHighest, keepLowest, dropHighest, dropLowest }
/// `crit` rolls every dice group twice; `crit!` (crunchy) adds each group's maximum to one roll. Modifiers count once.
enum DiceCrit: Hashable { case none, double, maximum }

/// One signed term of a dice line: a group of identical dice, or a whole-number modifier when `sides` is 0 (C# DiceTerm).
struct DiceTerm: Hashable {
    let sign: Int
    let count: Int
    let sides: Int
    let selection: DiceSelection
    let select: Int
    let constant: Int64
    init(_ sign: Int, _ count: Int, _ sides: Int, _ selection: DiceSelection = .all, _ select: Int = 0, constant: Int64 = 0) {
        self.sign = sign; self.count = count; self.sides = sides; self.selection = selection; self.select = select; self.constant = constant
    }
    var isDice: Bool { sides > 0 }
    /// How many of the group's dice count toward its subtotal.
    var kept: Int {
        switch selection {
        case .keepHighest, .keepLowest: return select
        case .dropHighest, .dropLowest: return count - select
        case .all: return count
        }
    }
    var notation: String {
        if !isDice { return String(constant) }
        let text = String(count) + "d" + String(sides)
        switch selection {
        case .keepHighest: return text + "kh" + String(select)
        case .keepLowest: return text + "kl" + String(select)
        case .dropHighest: return text + "dh" + String(select)
        case .dropLowest: return text + "dl" + String(select)
        case .all: return text
        }
    }
}

/// A parsed dice line such as `10d6+4`, `2d20kh1+5`, `crit 2d6+3` or `crit! 2d6+3` (C# DiceFormula). Immutable and entropy-free.
final class DiceFormula {
    let crit: DiceCrit
    /// How many times each dice group is rolled.
    var copies: Int { crit == .double ? 2 : 1 }
    let terms: [DiceTerm]
    /// Canonical notation; the persisted roll is valid only for this exact formula.
    let notation: String
    /// Sides of every die in roll order: each group, followed by its second roll on a `crit`.
    let sides: [Int]
    init(_ crit: DiceCrit, _ terms: [DiceTerm]) {
        self.crit = crit; self.terms = terms
        var notation = crit == .double ? "crit " : crit == .maximum ? "crit! " : ""
        for (i, term) in terms.enumerated() {
            if term.sign < 0 { notation += "-" } else if i > 0 { notation += "+" }
            notation += term.notation
        }
        self.notation = notation
        let copies = crit == .double ? 2 : 1
        sides = terms.filter(\.isDice).flatMap { [Int](repeating: $0.sides, count: $0.count * copies) }
    }
    /// A stored roll belongs to this formula only when every face is a possible result of its die.
    func fits(_ faces: [Int]?) -> Bool {
        guard let faces, faces.count == sides.count else { return false }
        return zip(faces, sides).allSatisfy { $0 >= 1 && $0 <= $1 }
    }
}

/// A document-owned roll for one statement (C# DiceBinding). Core never rolls; the document owner supplies faces.
struct DiceBinding: Hashable { let statement: UUID; let formula: String; let faces: [Int] }
struct DieFace: Hashable { let sides: Int; let face: Int; let kept: Bool }

final class DiceExpression: Expression { let formula: DiceFormula; init(_ formula: DiceFormula) { self.formula = formula } }

enum DiceSyntax {
    static let maxDicePerLine = 1000
    static let maxSides = 10_000
    static let maxTerms = 32
    static let maxModifier: Int64 = 1_000_000
    static let maxLabelWords = 8
    static let rollNote = "Ctrl+Enter rolls again; editing the dice clears the roll"
    static let critNote = "Critical: each dice group is rolled twice; modifiers count once"
    static let crunchyNote = "Crunchy critical: each dice group adds its maximum to its rolled dice; modifiers count once"

    /// Parses a dice line's expression text. Optional leading label words are ignored, as with numeric labels.
    /// A user variable named like a count-less die (`d6`) shadows the dice reading. `names` compares ignoring case.
    static func tryParse(_ text: String, _ names: NetHashSet<String>? = nil) throws -> DiceFormula? {
        let u = text.units
        if u.isEmpty || u.count > 4096 { return nil }
        var position = 0, words = 0
        while true {
            if let formula = parse(u, position, names) { return formula }
            if words >= maxLabelWords || !skipLabelWord(u, &position, names) { return nil }
            words += 1
        }
    }

    /// The dice formula on each source line, using the sheet's own variable names for shadowing. One pass over the sheet.
    static func formulas(_ source: String, _ token: CancellationToken = .none) throws -> NetDictionary<Int, DiceFormula> {
        var found = NetDictionary<Int, DiceFormula>()
        if !mentions(source) { return found }
        let lines = SheetEvaluator.splitLines(source)
        if lines.count > SheetEvaluator.maxLines || source.netLength > SheetEvaluator.maxCharacters { return found }
        var scanned: [ParsedLine] = []; var names = NetHashSet<String>.ignoringCase()
        for line in lines {
            try token.throwIfCancellationRequested()
            let parsed = try SheetSyntax.scan(line, token); scanned.append(parsed)
            if let name = parsed.assignment { names.insert(name) }
        }
        for (i, line) in scanned.enumerated() {
            if line.error != nil || line.boundary || line.directive != nil || line.functionName != nil || line.text.isEmpty { continue }
            if let formula = try tryParse(line.text, names) { found.set(i, formula) }
        }
        return found
    }

    /// A cheap pre-check: some `d` directly followed by a digit or `%`.
    static func mentions(_ source: String) -> Bool {
        let u = source.units
        for i in 0..<max(0, u.count - 1) where (u[i] == 0x64 || u[i] == 0x44) && (NetChar.isAsciiDigit(u[i + 1]) || u[i + 1] == 0x25) { return true }
        return false
    }

    private static func skipLabelWord(_ text: [UInt16], _ position: inout Int, _ names: NetHashSet<String>?) -> Bool {
        let start = position
        while position < text.count && NetChar.isWhiteSpace(text[position]) { position += 1 }
        let wordStart = position
        while position < text.count && (NetChar.isLetter(text[position]) || text[position] == 0x5F) { position += 1 }
        if position == wordStart || position < text.count && !NetChar.isWhiteSpace(text[position]) { position = start; return false }
        let word = text.string(wordStart, position)
        if word.equalsIgnoreCase("crit") || names?.contains(word) == true { position = start; return false }
        return true
    }

    private static func parse(_ text: [UInt16], _ start: Int, _ names: NetHashSet<String>?) -> DiceFormula? {
        var position = start
        func skip() { while position < text.count && NetChar.isWhiteSpace(text[position]) { position += 1 } }
        func isAny(_ c: UInt16, _ options: String) -> Bool { options.utf16.contains(c) }
        skip()
        var crit = DiceCrit.none
        if position + 4 <= text.count && text.string(position, position + 4).equalsIgnoreCase("crit") && names?.contains("crit") != true {
            // `crit!` may touch the dice; `crit` needs a space after it.
            if position + 4 < text.count && text[position + 4] == 0x21 { crit = .maximum; position += 5; skip() }
            else if position + 4 < text.count && NetChar.isWhiteSpace(text[position + 4]) { crit = .double; position += 4; skip() }
        }
        var terms: [DiceTerm] = []; var dice = 0
        while true {
            skip()
            var sign = 1
            if position < text.count && (text[position] == 0x2B || text[position] == 0x2D) { sign = text[position] == 0x2D ? -1 : 1; position += 1; skip() }
            else if !terms.isEmpty { return nil }
            if position >= text.count { return nil }
            let termStart = position
            let count = readNumber(text, &position)
            if count == -2 { return nil }
            if position < text.count && isAny(text[position], "dD") {
                position += 1
                let sides: Int
                if position < text.count && text[position] == 0x25 {
                    // `d%` is a percentage of a sheet variable named d.
                    if count == -1 && names?.contains("d") == true { return nil }
                    sides = 100; position += 1
                } else { sides = Int(min(Int64(Int32.max), readNumber(text, &position))); if sides < 0 { return nil } }
                // A count-less die named like a sheet variable is that variable.
                if count == -1 && names?.contains(text.string(termStart, position)) == true { return nil }
                let number = count == -1 ? 1 : count
                if number < 1 || number > Int64(maxDicePerLine) || sides < 1 || sides > maxSides { return nil }
                dice += Int(number); if dice > maxDicePerLine { return nil }
                var selection = DiceSelection.all; var select = 0
                if position < text.count && isAny(text[position], "kKdD") {
                    let keep = isAny(text[position], "kK"); position += 1
                    var high = true
                    if position < text.count && isAny(text[position], "hHlL") { high = isAny(text[position], "hH"); position += 1 }
                    else if !keep { return nil }
                    let amount = readNumber(text, &position)
                    if amount < 1 { return nil }
                    selection = keep ? (high ? .keepHighest : .keepLowest) : (high ? .dropHighest : .dropLowest)
                    if keep ? amount > number : amount >= number { return nil }
                    select = Int(amount)
                }
                terms.append(DiceTerm(sign, Int(number), sides, selection, select))
            } else if count >= 0 {
                if count > maxModifier { return nil }
                terms.append(DiceTerm(sign, 0, 0, constant: count))
            } else { return nil }
            if terms.count > maxTerms { return nil }
            if position < text.count && !NetChar.isWhiteSpace(text[position]) && text[position] != 0x2B && text[position] != 0x2D { return nil }
            skip()
            if position >= text.count { break }
        }
        // A doubled crit rolls twice as many dice; the per-line bound covers them all.
        return dice == 0 || crit == .double && dice * 2 > maxDicePerLine ? nil : DiceFormula(crit, terms)
    }

    /// Reads ASCII digits: -1 when none, -2 when the value is out of range.
    private static func readNumber(_ text: [UInt16], _ position: inout Int) -> Int64 {
        let start = position; var value: Int64 = 0
        while position < text.count && NetChar.isAsciiDigit(text[position]) {
            value = value * 10 + Int64(text[position] - 48); position += 1
            if value > maxModifier * 10 { return -2 }
        }
        return position == start ? -1 : value
    }

    /// Every rolled die in roll order, for presentation.
    static func faces(_ formula: DiceFormula, _ faces: [Int]) throws -> [DieFace] {
        if !formula.fits(faces) { throw CalcError.argument("Roll does not belong to this formula") }
        var dice: [DieFace] = []; var offset = 0
        for term in formula.terms where term.isDice {
            for _ in 0..<formula.copies {
                let rolled = Array(faces[offset..<(offset + term.count)]); offset += term.count
                let kept = keptMask(term, rolled)
                for i in rolled.indices { dice.append(DieFace(sides: term.sides, face: rolled[i], kept: kept[i])) }
            }
        }
        return dice
    }

    /// Which dice count toward their group, in roll order. Stable: equal faces resolve in roll order.
    static func keptMask(_ term: DiceTerm, _ faces: [Int]) -> [Bool] {
        var kept = [Bool](repeating: false, count: faces.count)
        if term.selection == .all { return [Bool](repeating: true, count: faces.count) }
        let high = term.selection == .keepHighest || term.selection == .dropLowest
        let order = faces.indices.stableSorted { high ? faces[$0] > faces[$1] : faces[$0] < faces[$1] }
        for i in order.prefix(term.kept) { kept[i] = true }
        return kept
    }

    static func total(_ formula: DiceFormula, _ faces: [Int]) throws -> (total: Int64, steps: [CalculationStep]) {
        var steps: [CalculationStep] = []; var parts: [String] = []; var summary = ""
        var total: Int64 = 0; var offset = 0; var listed = 0
        for term in formula.terms {
            if !summary.isEmpty || term.sign < 0 { summary += term.sign < 0 ? (!summary.isEmpty ? " − " : "−") : " + " }
            if !term.isDice {
                total += Int64(term.sign) * term.constant
                parts.append((term.sign < 0 ? "−" : "+") + format(term.constant))
                summary += format(term.constant)
                continue
            }
            var sum: Int64 = 0
            for copy in 0..<formula.copies {
                let rolled = Array(faces[offset..<(offset + term.count)]); offset += term.count
                let kept = keptMask(term, rolled)
                var subtotal: Int64 = 0; for i in rolled.indices where kept[i] { subtotal += Int64(rolled[i]) }
                func face(_ i: Int) -> String { kept[i] ? format(Int64(rolled[i])) : "(" + format(Int64(rolled[i])) + ")" }
                var shown = (0..<min(60, rolled.count)).map(face)
                if rolled.count > 60 { shown.append("… " + format(Int64(rolled.count - 60)) + " more") }
                let dropped: String? = term.selection == .all ? nil : "Parenthesized dice are dropped"
                steps.append(copy == 0 ? CalculationStep(term.notation, shown, format(subtotal), dropped)
                             : CalculationStep("crit " + term.notation + " again", shown, format(subtotal), dropped.map { critNote + "; " + $0 } ?? critNote))
                // The hover note lists the actual dice, bounded.
                if copy > 0 { summary += " + " }
                let room = max(1, 24 - listed); listed += min(room, rolled.count)
                summary += "[" + (0..<min(room, rolled.count)).map(face).joined(separator: ", ")
                summary += rolled.count > room ? ", …]" : "]"
                sum += subtotal
            }
            let maximum: Int64 = formula.crit == .maximum ? Int64(term.kept) * Int64(term.sides) : 0
            if maximum > 0 {
                steps.append(CalculationStep("crit! " + term.notation, [format(maximum) + " max", format(sum) + " rolled"], format(maximum + sum), crunchyNote))
                summary = summary.netInsert(summary.netLastIndexOf("["), format(maximum) + " + ")
            }
            sum += maximum
            total += Int64(term.sign) * sum
            parts.append((term.sign < 0 ? "−" : "+") + format(sum))
        }
        if let first = parts.first, first.hasPrefix("+") { parts[0] = first.netSubstring(1) }
        steps.append(CalculationStep("roll " + formula.notation, parts, format(total), summary + "; " + rollNote))
        return (total, steps)
    }

    /// The muted preview of an unrolled line: its possible range, with the average in the explanation.
    static func preview(_ formula: DiceFormula) throws -> (preview: String, steps: [CalculationStep]) {
        var minimum: Int64 = 0, maximum: Int64 = 0; var average = 0.0; var exact = true
        for term in formula.terms {
            var low: Int64, high: Int64, mean: Double, exactMean: Bool
            if !term.isDice { low = term.constant; high = term.constant; mean = Double(term.constant); exactMean = true }
            else {
                low = Int64(term.kept); high = Int64(term.kept) * Int64(term.sides)
                (mean, exactMean) = groupAverage(term)
                if formula.crit == .double { low *= 2; high *= 2; mean *= 2 }
                if formula.crit == .maximum { let bonus = Int64(term.kept) * Int64(term.sides); low += bonus; high += bonus; mean += Double(bonus) }
            }
            if term.sign < 0 { (low, high, mean) = (-high, -low, -mean) }
            minimum += low; maximum += high; average += mean; exact = exact && exactMean
        }
        let range = minimum == maximum ? format(minimum) : format(minimum) + "–" + format(maximum)
        let averageText: String? = average.isNaN ? nil : exact ? "average " + format(average) : "average ≈" + format(average)
        let critText = formula.crit == .double ? "; " + critNote : formula.crit == .maximum ? "; " + crunchyNote : ""
        let note = (averageText.map { $0 + "; " } ?? "") + "press Enter to roll" + critText
        return (range, [CalculationStep("range " + formula.notation, [], range, note)])
    }

    private static func format(_ value: Int64) -> String { value < 0 ? "−" + String(-value) : String(value) }
    private static func format(_ value: Double) -> String {
        let text = NetFormat.double(NetMath.round(Swift.abs(value), 2), "0.##")
        return value < 0 && text != "0" ? "−" + text : text
    }

    /// Expected group subtotal. Plain groups are exact; kept/dropped groups use order statistics up to a bound, else NaN.
    private static func groupAverage(_ term: DiceTerm) -> (mean: Double, exact: Bool) {
        if term.selection == .all { return (Double(term.count * (term.sides + 1)) / 2.0, true) }
        if term.count > 100 || term.sides > 1000 { return (.nan, false) }
        // E[sum of the k highest] = Σ_j E[X_(j)], where P(X_(j) ≥ x) is the chance that at least n−j+1 dice show ≥ x.
        let n = term.count; let high = term.selection == .keepHighest || term.selection == .dropLowest
        var mean = 0.0
        for x in 1...term.sides {
            let p = Double(term.sides - x + 1) / Double(term.sides)
            var atLeast = [Double](repeating: 0, count: n + 2) // atLeast[m] = P(at least m dice ≥ x)
            var pmf = [Double](repeating: 0, count: n + 1)
            for m in 0...n { pmf[m] = binomial(n, m) * Foundation.pow(p, Double(m)) * Foundation.pow(1 - p, Double(n - m)) }
            for m in stride(from: n, through: 0, by: -1) { atLeast[m] = atLeast[m + 1] + pmf[m] }
            // The kept dice are the top k (high) or bottom k (low): ranks n..n−k+1 or 1..k.
            if term.kept >= 1 {
                for r in 1...term.kept {
                    let rank = high ? n - r + 1 : r // rank-th smallest
                    mean += atLeast[n - rank + 1]
                }
            }
        }
        return (mean, false)
    }
    private static func binomial(_ n: Int, _ k: Int) -> Double {
        var result = 1.0; let k = min(k, n - k)
        if k >= 1 { for i in 1...k { result = result * Double(n - k + i) / Double(i) } }
        return result
    }
}
