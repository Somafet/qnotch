import XCTest
@testable import CalculatorEngine

final class UuidTests: XCTestCase {
    /// C# `new Guid(index, 0, 0, new byte[8])`.
    private static func node(_ index: Int) -> UUID { UUID(uuidString: String(format: "%08x-0000-0000-0000-000000000000", index))! }
    private static func uuid(_ index: Int) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-" + String(format: "%012x", index))! }
    private static func context(_ rows: Int = 16) throws -> StableUuidContext {
        let ids = (1...rows).map(node); let sites = ["/0", "/2", "/3", "/4", "/0:MAKE/0"]
        return try StableUuidContext(ids, ids.enumerated().flatMap { i, id in sites.enumerated().map { j, site in UuidBinding(statement: id, site: site, value: uuid(i * sites.count + j + 1)) } })
    }
    private static func with(_ uuids: StableUuidContext?) -> EvaluationContext { EvaluationContext().with { $0.uuids = uuids } }
    private func value(_ source: String, _ input: StableUuidContext? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let row = try SheetEvaluator.evaluate(source, context: UuidTests.with(try input ?? UuidTests.context())).last!
        XCTAssertNil(row.error, source, file: file, line: line)
        return try XCTUnwrap(row.value, source, file: file, line: line).text.value
    }

    func testIndependentUuidInputAndFormat() throws {
        let cases = try JSONNode.parse(try Fixtures.data("uuid-v1.json")).property("cases").arrayItems()
        for row in cases {
            CaseCounter.record(file: #filePath)
            let expected = try row.property("value").string()
            do {
                let id = try XCTUnwrap(UUID.parse(try row.property("node").string())); let uuid = try XCTUnwrap(UUID.parse(expected))
                let input = try StableUuidContext([id], [UuidBinding(statement: id, site: "/0", value: uuid)])
                XCTAssertEqual(expected, try value("uuid", input)); XCTAssertEqual(expected, try value("uuid()", input))
                let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
                XCTAssertEqual(try row.property("networkBytes").string(), TextArithmetic.hex(bytes), expected); XCTAssertTrue(StableUuidContext.isVersion4(uuid), expected)
            } catch { XCTFail("\(expected): \(error)") }
        }
    }

    func testValuesAreStableDistinctComposableAndScopedByContext() throws {
        let input = try UuidTests.context(); let source = "a=uuid\nb=uuid()\na\nbase64(a)"
        let rows = try SheetEvaluator.evaluate(source, context: UuidTests.with(input)); for r in rows { XCTAssertNil(r.error) }
        let a = try rows[0].value!.text.value; let b = try rows[1].value!.text.value
        XCTAssertNotEqual(a, b); XCTAssertEqual(a, try rows[2].value!.text.value); XCTAssertEqual(Data(a.utf8).base64EncodedString(), rows[3].display)
        let units = Array(a.utf16)
        XCTAssertEqual(UInt16(ascii: "4"), units[14]); XCTAssertTrue("89ab".utf16.contains(units[19])); XCTAssertEqual(UUID(uuidString: a)?.dashed, a); XCTAssertEqual(a, try value("uuid", input))
        XCTAssertEqual(a, try value("uuid()", input)); XCTAssertNotEqual(a, try value("sha256(uuid)", input))
        let fn = "make()=uuid\nmake()\nmake()"; let calls = try SheetEvaluator.evaluate(fn, context: UuidTests.with(input))
        XCTAssertNotEqual(calls[1].display, calls[2].display); XCTAssertEqual(calls[calls.count - 1].display, try value(fn, input))
        XCTAssertNotEqual(a, try value("uuid", try StableUuidContext([UuidTests.node(99)], [UuidBinding(statement: UuidTests.node(99), site: "/0", value: UuidTests.uuid(999))])))
    }

    func testInvalidArgumentsAndNumericOperationsFail() throws {
        try theory(["uuid(1)", "uuid(\"x\")", "uuid()+1", "uuid in hex"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source, context: UuidTests.with(try UuidTests.context())).last!.error, source)
        }
    }

    func testGenerationRequiresExplicitContextAndInvalidatesOnlyReaders() throws {
        let session = SheetEvaluationSession(); let first = try session.evaluate("uuid\n2+2"); XCTAssertTrue(first[0].error!.contains("context"))
        let next = try session.evaluate("uuid\n2+2", context: UuidTests.with(try UuidTests.context())); XCTAssertNil(next[0].error); XCTAssertTrue(first[1] === next[1])
        let again = try session.evaluate("uuid\n2+2", context: UuidTests.with(try UuidTests.context())); XCTAssertTrue(next[0] === again[0])
        let fresh = try session.evaluate("uuid\n2+2", context: UuidTests.with(try StableUuidContext([UuidTests.node(99), UuidTests.node(100)],
                                                                                                    [UuidBinding(statement: UuidTests.node(99), site: "/0", value: UuidTests.uuid(999))])))
        XCTAssertNotEqual(next[0].display, fresh[0].display); XCTAssertTrue(next[1] === fresh[1])
    }

    func testOnlyActualGenerationEnablesState() throws {
        try theory([("uuid", true), ("uuid()", true), ("text(\"uuid\")", false), ("# uuid", false),
                    ("uuid=7\nuuid+1", false), ("make()=uuid", false), ("make()=uuid\nmake()", true),
                    ("uuid(1)", false)]) { source, expected in
            XCTAssertEqual(expected, try UuidSyntax.requiresState(source), source)
        }
    }

    func testPendingDiscoveryNeverPublishesPlaceholderValuesOrTraces() throws {
        let ids = (1...5).map(UuidTests.node); let input = try StableUuidContext(ids, []); let session = SheetEvaluationSession()
        let pending = try session.evaluateWithFunctions("a=uuid\nb=uuid()\na\nbase64(a)\n2+2", .empty, [], context: UuidTests.with(input))
        XCTAssertEqual(2, pending.uuidRequests.count)
        for r in pending.results.prefix(4) { XCTAssertNil(r.value); XCTAssertEqual("UUID generation pending", r.error); XCTAssertTrue(r.explanation.isEmpty) }
        XCTAssertEqual("4", pending.results[4].display)
        let bindings = pending.uuidRequests.enumerated().map { i, r in UuidBinding(statement: ids[r.line], site: r.site, value: UuidTests.uuid(i + 1)) }
        let complete = try session.evaluateWithFunctions("a=uuid\nb=uuid()\na\nbase64(a)\n2+2", .empty, [], context: UuidTests.with(try StableUuidContext(ids, bindings)))
        XCTAssertTrue(complete.uuidRequests.isEmpty); for r in complete.results { XCTAssertNil(r.error) }; XCTAssertEqual(complete.results[0].display, complete.results[2].display)
    }

    func testSnapshotIsImmutableAndBoundsAndCancellationHold() throws {
        var ids = [UuidTests.node(1)]; var bindings = [UuidBinding(statement: ids[0], site: "/0", value: UuidTests.uuid(1))]
        let input = try StableUuidContext(ids, bindings); let stored = try value("uuid", input)
        ids[0] = UuidTests.node(2); bindings[0] = UuidBinding(statement: UuidTests.node(2), site: "/0", value: UuidTests.uuid(2)); XCTAssertEqual(stored, try value("uuid", input))
        func isArgument(_ error: Error) -> Bool { (error as? CalcError)?.isArgument == true }
        XCTAssertThrowsError(try StableUuidContext([.empty], [])) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try StableUuidContext([UuidTests.node(1), UuidTests.node(1)], [])) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try StableUuidContext([UuidTests.node(1)], [UuidBinding(statement: UuidTests.node(1), site: "/0", value: .empty)])) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try StableUuidContext([UuidTests.node(1)], [UuidBinding(statement: UuidTests.node(1), site: "/0", value: UuidTests.uuid(1)),
                                                                        UuidBinding(statement: UuidTests.node(1), site: "/0", value: UuidTests.uuid(2))])) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try StableUuidContext((1...10001).map(UuidTests.node), [])) { XCTAssertTrue(isArgument($0)) }
        XCTAssertThrowsError(try StableUuidContext([UuidTests.node(1)], (0..<1025).map { UuidBinding(statement: UuidTests.node(1), site: "/" + String($0), value: UuidTests.uuid($0 + 1)) })) { XCTAssertTrue(isArgument($0)) }
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try UuidSyntax.requiresState("uuid", token: cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
