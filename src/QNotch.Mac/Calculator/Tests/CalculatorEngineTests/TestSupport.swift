import XCTest
@testable import CalculatorEngine

/// Runs one xUnit [Theory] row per element and counts the rows, so Swift and C# case counts can be compared.
func theory<T>(_ rows: [T], file: StaticString = #filePath, line: UInt = #line, function: String = #function, _ body: (T) throws -> Void) throws {
    for row in rows {
        do { try body(row) } catch { XCTFail("\(row): \(error)", file: file, line: line) }
        CaseCounter.record(file: "\(file)", function: function)
    }
}
/// Counts xUnit-equivalent cases: each theory row or fixture case counts one, each other test method one.
/// `ZZCaseCountReport` (which runs last) writes the per-class totals to `<package>/.build/calculator-case-counts.json`.
enum CaseCounter {
    private static let lock = NSLock()
    private static var rows: [String: [String: Int]] = [:]
    /// Records `count` cases for the calling test method. The class is named after its file, by convention.
    static func record(file: String, function: String = #function, count: Int = 1) {
        let name = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        lock.lock(); rows[name, default: [:]][function, default: 0] += count; lock.unlock()
    }
    static func rows(for testClass: String) -> [String: Int] { lock.lock(); defer { lock.unlock() }; return rows[testClass] ?? [:] }
}
/// System.Random(seed): .NET's seeded generator (Knuth's subtractive method), so fuzz tests see the same inputs as C#.
struct NetRandom {
    private var seedArray = [Int32](repeating: 0, count: 56)
    private var inext = 0, inextp = 21
    init(_ seed: Int32) {
        let subtraction = seed == Int32.min ? Int32.max : abs(seed)
        var mj = 161803398 - subtraction
        seedArray[55] = mj
        var mk: Int32 = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21; if ii >= 55 { ii -= 55 }
            seedArray[ii] = mk
            mk = mj &- mk
            if mk < 0 { mk = mk &+ Int32.max }
            mj = seedArray[ii]
        }
        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30; if n >= 55 { n -= 55 }
                seedArray[i] = seedArray[i] &- seedArray[1 + n]
                if seedArray[i] < 0 { seedArray[i] = seedArray[i] &+ Int32.max }
            }
        }
    }
    private mutating func internalSample() -> Int32 {
        var locINext = inext + 1; if locINext >= 56 { locINext = 1 }
        var locINextp = inextp + 1; if locINextp >= 56 { locINextp = 1 }
        var retVal = seedArray[locINext] &- seedArray[locINextp]
        if retVal == Int32.max { retVal -= 1 }
        if retVal < 0 { retVal = retVal &+ Int32.max }
        seedArray[locINext] = retVal
        inext = locINext; inextp = locINextp
        return retVal
    }
    private mutating func sample() -> Double { Double(internalSample()) * (1.0 / Double(Int32.max)) }
    /// Random.Next(maxValue).
    mutating func next(_ maxValue: Int) -> Int { Int(sample() * Double(maxValue)) }
    /// Random.Next(minValue, maxValue).
    mutating func next(_ minValue: Int, _ maxValue: Int) -> Int {
        let range = Int64(maxValue) - Int64(minValue)
        return Int(Int64(sample() * Double(range)) + Int64(minValue))
    }
}

/// Evaluates a sheet with the default context.
func evaluate(_ source: String, context: EvaluationContext? = nil) throws -> [LineResult] { try SheetEvaluator.evaluate(source, context: context) }

/// decimal.Round(value, places, MidpointRounding.AwayFromZero) on an exact value.
func roundAwayFromZero(_ value: Rational, places: Int = 0) throws -> Rational {
    let scale = BigInt.pow(10, places)
    let scaled = try value * Rational(scale)
    var (q, r) = scaled.numerator.magnitude.quotientAndRemainder(dividingBy: scaled.denominator)
    if r * 2 >= scaled.denominator { q = q + 1 }
    return try Rational(BigInt(scaled.sign < 0 ? -1 : 1) * q, scale)
}
/// The one evaluated number of a single-line sheet (fails the test on an error).
func number(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> NumericValue {
    let result = try SheetEvaluator.evaluate(source)[0]
    XCTAssertNil(result.error, source, file: file, line: line)
    guard let value = result.value else { throw CalcError.format("no value for " + source) }
    return try value.number
}
