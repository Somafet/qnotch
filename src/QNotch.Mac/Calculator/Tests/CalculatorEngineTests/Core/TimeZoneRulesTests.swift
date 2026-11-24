import Foundation
import XCTest
@testable import CalculatorEngine

/// Checks the embedded TZDB rules (Support/Tzdb.swift over Resources/Tzdb.txt) against NodaTime 3.3.7: for every
/// zone, Vectors/TzdbCheck.txt (written by Tools/TzdbExport's "check" mode) holds the FNV-1a hash of offsets at
/// pseudo-random instants, MapLocal results at pseudo-random local times, and every transition in its year range
/// with MapLocal probes around it. This test regenerates the same cases from the Swift rules. No C# counterpart.
///
/// Exhaustive run: generate a denser file with the tool (e.g. "check /path/out.txt 200000 200000 1 10000") and run
/// this test with TZDB_CHECK_FILE=/path/out.txt (release build recommended). TZDB_TRACE=<id> prints one zone's cases
/// for diffing against the tool's output with the same variable.
final class TimeZoneRulesTests: XCTestCase {
    func testEveryZoneMatchesNodaTime() throws {
        let path = ProcessInfo.processInfo.environment["TZDB_CHECK_FILE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vectors/TzdbCheck.txt").path
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var parameters: [Int] = [], expected: [(id: String, count: Int, hash: String)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            if fields[0] == "C" { parameters = fields.dropFirst().map { Int($0)! } } else { expected.append((String(fields[0]), Int(fields[1])!, String(fields[2]))) }
        }
        XCTAssertEqual(parameters.count, 4)
        let provider = Tzdb.provider as! TzdbProvider
        XCTAssertEqual(expected.map(\.id), provider.ids, "The check file and Tzdb.txt list different ids")
        let trace = ProcessInfo.processInfo.environment["TZDB_TRACE"]
        var failures = 0
        for want in expected {
            let lines = TimeZoneRulesTests.cases(try XCTUnwrap(provider.zone(want.id)), id: want.id, instants: parameters[0], locals: parameters[1], fromYear: parameters[2], toYear: parameters[3])
            if want.id == trace { print(lines.joined(separator: "\n")) }
            let hash = Oracle.hex(Oracle.fnv(lines.joined(separator: "\n")))
            if lines.count != want.count || hash != want.hash {
                failures += 1
                if failures <= 10 { XCTFail("\(want.id): \(lines.count) cases hashing to \(hash); NodaTime gave \(want.count) cases hashing to \(want.hash)") }
            }
        }
        XCTAssertEqual(failures, 0, "zones differing from NodaTime")
    }

    /// Mirrors Check() in Tools/TzdbExport/Program.cs line for line.
    static func cases(_ zone: ZoneRules, id: String, instants: Int, locals: Int, fromYear: Int, toYear: Int) -> [String] {
        let minTicks: Int64 = -621_355_968_000_000_000, maxTicks: Int64 = 2_534_023_007_999_999_999
        var lines: [String] = []
        func map(_ local: Int64) -> String {
            let offsets = zone.mapLocal(local)
            return ([String(offsets.count)] + offsets.map(String.init)).joined(separator: " ")
        }
        var random = SplitMix64(Oracle.fnv(id))
        for _ in 0..<instants {
            let ticks = minTicks + Int64(random.next() % UInt64(maxTicks - minTicks + 1))
            lines.append("o \(ticks) \(zone.offsetSeconds(at: Instant(unixTicks: ticks)))")
        }
        for _ in 0..<locals {
            let local = Int64(random.next() % UInt64(Ticks.maxDateTime + 1))
            lines.append("m \(local) " + map(local))
        }
        func yearStart(_ year: Int) -> Int64 { year > 9999 ? maxTicks + 1 : Int64(DateOnly(year, 1, 1)!.dayNumber) * Ticks.perDay - Ticks.unixEpoch }
        let from = yearStart(fromYear), to = yearStart(toYear)
        // Fixed zones have a single interval: no transitions.
        guard let zone = zone as? TzdbZone else { return lines }
        var interval = zone.interval(from)
        while NodaTicks.isValid(interval.end) && interval.end < to {
            let at = interval.end, next = zone.interval(at)
            let before = interval.wallOffset, after = next.wallOffset
            lines.append("t \(at) \(before) \(after)")
            for wall in [before, after] {
                for delta in [-Ticks.perSecond, -1, 0, 1, Ticks.perSecond] {
                    let local = at + Ticks.unixEpoch + Int64(wall) * Ticks.perSecond + delta
                    if local >= 0 && local <= Ticks.maxDateTime { lines.append("m \(local) " + map(local)) }
                }
            }
            interval = next
        }
        return lines
    }
}
