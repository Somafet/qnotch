import Foundation

// Port of SalaryExpressions.cs: the salary sentence grammar and its options records.

/// Romanian salary options (C# record RomanianSalaryOptions).
struct RomanianSalaryOptions: Hashable {
    var dependants: Int? = nil
    var schoolChildren = 0
    var youthRelief = false
    var minimumRelief = true
    var mainJob = true
    var basicSalary: Int? = nil
}

/// `amount gross/net in gross …` (C# record SalaryExpression).
final class SalaryExpression: Expression {
    let amount: Expression, inverse: Bool, country: String?, year: Int?, outputPeriod: EarningsPeriod?
    let payrollDate: DateOnly?, romanian: RomanianSalaryOptions?, employerCost: Bool
    let german: GermanSalaryOptions?, hungarian: HungarianSalaryOptions?
    init(_ amount: Expression, _ inverse: Bool, country: String? = nil, year: Int? = nil, outputPeriod: EarningsPeriod? = nil,
         payrollDate: DateOnly? = nil, romanian: RomanianSalaryOptions? = nil, employerCost: Bool = false,
         german: GermanSalaryOptions? = nil, hungarian: HungarianSalaryOptions? = nil) {
        self.amount = amount; self.inverse = inverse; self.country = country; self.year = year; self.outputPeriod = outputPeriod
        self.payrollDate = payrollDate; self.romanian = romanian; self.employerCost = employerCost; self.german = german; self.hungarian = hungarian
    }
    var children: [Expression] { [amount] }
}

/// C# `int.TryParse(text, out value)` (NumberStyles.Integer): optional surrounding white space and one leading sign,
/// ASCII digits, within Int32.
func netInt32TryParse(_ text: String) -> Int? {
    var units = text.units[...]
    func white(_ c: UInt16) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }
    while let first = units.first, white(first) { units = units.dropFirst() }
    while let last = units.last, white(last) { units = units.dropLast() }
    var negative = false
    if let first = units.first, first == 0x2D || first == 0x2B { negative = first == 0x2D; units = units.dropFirst() }
    if units.isEmpty { return nil }
    var value: Int64 = 0
    for unit in units {
        guard NetChar.isAsciiDigit(unit) else { return nil }
        value = value * 10 + Int64(unit - 48)
        if value > Int64(Int32.max) + 1 { return nil }
    }
    if negative { value = -value }
    return value >= Int64(Int32.min) && value <= Int64(Int32.max) ? Int(value) : nil
}

extension ExpressionParser {
    /// TrySalarySentence: `amount gross|brut|brutto [in country] …` or `amount net in gross …`, with options.
    func trySalarySentence() throws -> Expression? {
        if tokens.count < 2 { return nil }
        if let knownNames, knownNames.contains(tokens.map(\.text).joined(separator: " ")) { return nil }
        var marker = -1, nesting = 0
        for i in 0..<tokens.count {
            try cancellationToken.throwIfCancellationRequested(); let text = tokens[i].text.netLower
            if text == "(" || text == "[" { nesting += 1 } else if text == ")" || text == "]" { nesting -= 1 }
            else if i > 0 && nesting == 0 && knownNameLength(i) == 0 && (text == "gross" || text == "brut" || text == "brutto" || text == "net") { marker = i; break }
        }
        if marker < 0 { return nil }
        let inverse = tokens[marker].text.equalsIgnoreCase("net"); var tail = marker + 1
        if inverse {
            // Leave invoice 'date net N' to its own parser.
            if tail + 1 >= tokens.count || !tokens[tail].text.equalsIgnoreCase("in") { return nil }
            let target = tokens[tail + 1].text.netLower
            if target != "gross" && target != "brut" && target != "brutto" { return nil }
            tail += 2
        }
        var country: String? = nil, year: Int? = nil, period: EarningsPeriod? = nil, payrollDate: DateOnly? = nil
        var ro: RomanianSalaryOptions? = nil, de: GermanSalaryOptions? = nil, hu: HungarianSalaryOptions? = nil, employerCost = false
        var optionsSeen = NetHashSet<String>.ignoringCase()
        func takeTail(_ text: String) -> Bool {
            if tail < tokens.count && tokens[tail].text.equalsIgnoreCase(text) { tail += 1; return true }
            return false
        }
        func once(_ name: String) throws { if !optionsSeen.insert(name) { throw CalcError.format("Duplicate salary option: " + name) } }
        func decimal(_ what: String, _ max: NetDecimal, _ places: Int) throws -> NetDecimal {
            guard tail < tokens.count, let parsed = NetDecimal.parse(tokens[tail].text), !(parsed > max), parsed.rounded(places) == parsed else {
                throw CalcError.format("Expected \(what)")
            }
            tail += 1; return parsed
        }
        func romanian(_ change: (inout RomanianSalaryOptions) -> Void) { var options = ro ?? RomanianSalaryOptions(); change(&options); ro = options }
        func german(_ change: (inout GermanSalaryOptions) -> Void) { var options = de ?? GermanSalaryOptions(); change(&options); de = options }
        func hungarian(_ change: (inout HungarianSalaryOptions) -> Void) { var options = hu ?? HungarianSalaryOptions(); change(&options); hu = options }
        while tail < tokens.count {
            let word = tokens[tail].text.netLower; tail += 1
            if word == "for" {
                if year != nil || payrollDate != nil || tail >= tokens.count { throw CalcError.format("Expected one salary tax year or payroll date") }
                if let literal = try DateSyntax.tryLiteral(tokens, tail) { payrollDate = literal.date; tail += literal.length }
                else {
                    let text = tokens[tail].text; tail += 1
                    guard text.netLength == 4, let parsedYear = netInt32TryParse(text), parsedYear >= 1 else {
                        throw CalcError.format("Expected a four-digit salary tax year or full payroll date")
                    }
                    year = parsedYear
                }
            } else if word == "in" || word == "to" {
                if tail >= tokens.count { throw CalcError.format("Missing salary target or country") }
                let target = tokens[tail].text; tail += 1
                if !inverse && target.equalsIgnoreCase("net") { continue }
                if target.equalsIgnoreCase("employer") && takeTail("cost") { try once("employer cost"); employerCost = true }
                else if let targetPeriod = ExpressionParser.earningsTarget(target) {
                    if period != nil { throw CalcError.format("Duplicate salary output period") }
                    period = targetPeriod
                } else {
                    if country != nil || target.netLength != 2 || !target.utf16.allSatisfy(NetChar.isAsciiLetter) {
                        throw CalcError.format("Expected a two-letter salary country or earnings period")
                    }
                    country = target.netUpper
                }
            } else if word == "as" {
                if !takeTail("pensioner") { throw CalcError.format("Expected as pensioner") }
                try once("pensioner"); hungarian { $0.pensioner = true }
            } else if word == "with" || word == "without" || word == "and" {
                if word == "without" {
                    if takeTail("minimum") && takeTail("relief") { try once("minimum relief"); romanian { $0.minimumRelief = false } }
                    else if takeTail("main") && takeTail("job") { try once("main job"); romanian { $0.mainJob = false } }
                    else if takeTail("childless") && takeTail("surcharge") { try once("childless surcharge"); german { $0.childlessSurcharge = false } }
                    else { throw CalcError.format("Expected without minimum relief, main job or childless surcharge") }
                } else if takeTail("youth") && takeTail("relief") { try once("youth relief"); romanian { $0.youthRelief = true } }
                else if takeTail("basic") && takeTail("salary") {
                    try once("basic salary")
                    var basic: Int? = nil
                    if tail < tokens.count { basic = netInt32TryParse(tokens[tail].text); tail += 1 }
                    guard let basic, basic >= 1, basic <= PayrollArithmetic.maxAnnualGross else { throw CalcError.format("Expected a positive whole-leu basic salary") }
                    romanian { $0.basicSalary = basic }
                } else if takeTail("tax") && takeTail("class") {
                    try once("tax class")
                    var klass: Int? = nil
                    if tail < tokens.count { klass = netInt32TryParse(tokens[tail].text); tail += 1 }
                    guard let klass, klass >= 1, klass <= 6 else { throw CalcError.format("Expected German tax class 1 through 6") }
                    german { $0.taxClass = klass }
                } else if takeTail("church") && takeTail("tax") {
                    try once("church tax"); var rate = 9
                    if tail + 1 < tokens.count && tokens[tail + 1].text == "%" {
                        if tokens[tail].text != "8" && tokens[tail].text != "9" { throw CalcError.format("Expected church tax 8% or 9%") }
                        rate = tokens[tail].text == "8" ? 8 : 9; tail += 2
                    }
                    german { $0.churchTaxPercent = rate }
                } else if takeTail("child") && takeTail("allowance") {
                    try once("child allowance"); let count = try decimal("a child allowance count in steps of 0.5 up to 20", NetDecimal(20), 1)
                    let doubled = try count * NetDecimal(2)
                    if doubled != doubled.truncated { throw CalcError.format("Expected a child allowance count in steps of 0.5 up to 20") }
                    german { $0.childAllowances = count }
                } else if takeTail("health") && takeTail("surcharge") {
                    try once("health surcharge"); let rate = try decimal("a health surcharge percentage up to 10 with two decimals", NetDecimal(10), 2)
                    if !takeTail("%") { throw CalcError.format("Expected % after the health surcharge") }
                    german { $0.healthSurchargePercent = rate }
                } else if takeTail("Saxony") { try once("Saxony"); german { $0.saxony = true } }
                else if takeTail("átalányadó") || takeTail("atalanyado") || takeTail("átalányadózás") || takeTail("atalanyadozas") || takeTail("flat") && takeTail("rate") {
                    try once("átalányadó"); hungarian { $0.flatRate = true }
                } else if takeTail("cost") && takeTail("ratio") {
                    try once("cost ratio")
                    if tail + 1 >= tokens.count || tokens[tail + 1].text != "%" || !["45", "80", "90"].contains(tokens[tail].text) {
                        throw CalcError.format("Expected átalányadó cost ratio 45%, 80% or 90%")
                    }
                    let ratio = Int(tokens[tail].text)!
                    hungarian { $0.costRatio = ratio }; tail += 2
                } else if takeTail("guaranteed") && takeTail("minimum") { try once("guaranteed minimum"); hungarian { $0.guaranteedMinimum = true } }
                else if (takeTail("mothers") || takeTail("mother")) && takeTail("exemption") { try once("mothers exemption"); hungarian { $0.mothersExemption = true } }
                else if takeTail("first") && takeTail("marriage") { try once("first marriage"); hungarian { $0.firstMarriage = true } }
                else {
                    var count: Int? = nil
                    if tail < tokens.count { count = netInt32TryParse(tokens[tail].text); tail += 1 }
                    guard let count, count >= 0, count <= 100 else { throw CalcError.format("Expected a salary dependant/child count from 0 through 100") }
                    if takeTail("dependant") || takeTail("dependants") || takeTail("dependent") || takeTail("dependents") { try once("dependants"); romanian { $0.dependants = count } }
                    else if takeTail("school") && (takeTail("child") || takeTail("children")) { try once("school children"); romanian { $0.schoolChildren = count } }
                    else if takeTail("child") || takeTail("children") { try once("children"); german { $0.children = count } }
                    else { throw CalcError.format("Expected dependants, school children or children") }
                }
            } else {
                throw CalcError.format("Unexpected salary text; use amount gross/net in gross in a country, optionally for a tax year or payroll date")
            }
        }
        let amount = try sub(0, marker).parse()
        return SalaryExpression(amount, inverse, country: country, year: year, outputPeriod: period, payrollDate: payrollDate, romanian: ro,
                                employerCost: employerCost, german: de, hungarian: hu)
    }
}
