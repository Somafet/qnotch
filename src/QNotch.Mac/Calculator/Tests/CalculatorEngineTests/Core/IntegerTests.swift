import XCTest
@testable import CalculatorEngine

final class IntegerTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        let result = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(result.error, source, file: file, line: line)
        return try XCTUnwrap(result.value, source, file: file, line: line)
    }
    private static func isFormat(_ error: Error) -> Bool { (error as? CalcError)?.isFormat == true }

    func testIndependentBitListOracle() throws {
        let cases = try JSONNode.parse(try Fixtures.data("integers-v1.json")).property("cases").arrayItems()
        for row in cases {
            CaseCounter.record(file: #filePath)
            let source = try row.property("source").string()
            do {
                let value = try last(source).integer
                XCTAssertEqual(BigInt(try row.property("value").string()), value.value, source)
                XCTAssertEqual(try row.property("width").int(), value.width, source); XCTAssertEqual(try row.property("signed").bool(), value.signed, source)
                let copied = try last(try value.copyText).integer
                XCTAssertEqual(value.value, copied.value, source); XCTAssertEqual(value.width, copied.width, source)
                XCTAssertEqual(value.signed, copied.signed, source); XCTAssertEqual(value.fullText, copied.fullText, source)
            } catch { XCTFail("\(source): \(error)") }
        }
    }

    func testPublishedExamplesAndContracts() throws {
        try theory([("255 in hex", "0xFF"), ("10 in binary", "0b1010"), ("255 in bin 8 bits", "0b11111111"), ("-1 in hex u8", "0xFF"), ("300 in u8", "44"),
                    ("0xF0 & 0x3C", "0x30"), ("1 << 4", "16"), ("0xFF in i8", "-1"), ("-1 in hex", "-0x1"), ("0o17 + 0b1", "0o20"), ("0xF_F + 1", "0x100"),
                    ("(255 in u8)+1", "0"), ("(127 in i8)+1", "-128"), ("(1 in u8)-2", "255"), ("(0x81 in i8) >> 1", "-64"), ("(0x81 in i8) >>> 1", "64"),
                    ("~0xF0", "-0xF1"), ("(0xF0 in hex u8) & 0x3C", "0x30"), ("1|2", "3"), ("1 | 2 xor 3 & 4 << 1 + 1", "3"), ("2^3", "8"), ("0x2^3", "0x8"),
                    ("100+10%", "110"), ("(3 in u8)/2", "1.5"), ("(4 in u8)/2", "2"), ("(3 in u8)^-1", "1/3"), ("(3 in u8)+0.5", "3.5"), ("(3 in u8)*2 m", "6 m"),
                    ("abs(-0x20)", "32"), ("bitand(0xF0,0x3C)", "0x30"), ("bitnot(uint(0,8))", "255"), ("mask=0xF0\ninput=0x3C\nmask & input", "0x30"),
                    ("flag 0xFF", "0xFF"), ("x=0xFF\nsum", "255")]) { source, display in
            XCTAssertEqual(display, try last(source).display, source)
        }
    }

    func testInvalidInputsAreErrors() throws {
        try theory(["0x", "0b2", "0o8", "0xGG", "0x_F", "0xF_", "0xF__F",
                    "1 in u0", "1 in i4097", "1 in bin 0 bits", "1 in hex 1.5 bits",
                    "1 << -1", "1 >> 4097", "-1 >>> 1", "1 & 1.5", "2% | 1", "2 m & 1",
                    "uint(1.5,8)", "hex(2%)", "hex(sqrt(2))", "uint(1,1.5)",
                    "(1 in u8)+(1 in i8)", "(1 in u8)&(1 in u16)",
                    "hex(1,2)", "bitand(1)", "uint(1)", "sint(1,8,3)"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testMaximumWordsKeepCompleteCopyAndBoundedDisplay() throws {
        let value = try last("-1 in bin u4096").integer
        XCTAssertEqual(4098, value.fullText.netLength); XCTAssertTrue(try value.display.netLength < 128); XCTAssertTrue(try value.display.contains("…"))
        XCTAssertEqual(value, try last(try value.copyText).integer)
        XCTAssertEqual(BigInt.one << 4095, try last("1 << 4095").integer.value)
        XCTAssertNotNil(try SheetEvaluator.evaluate("1 << 4096")[0].error)
        XCTAssertNotNil(try SheetEvaluator.evaluate("0x1" + String(repeating: "0", count: 1024))[0].error)
        XCTAssertEqual(BigInt.zero, try last("(-1 in u4096) << 4096").integer.value)
        XCTAssertEqual(-BigInt.one, try last("(-1 in i4096) >> 4096").integer.value)
        XCTAssertEqual(BigInt.zero, try last("(-1 in i4096) >>> 4096").integer.value)
    }

    func testFunctionsPreserveWordProfilesAndRejectBadArityAtDeclaration() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "mask", parameters: ["x"], body: "(x in hex u8) & 0xF0"), FunctionDefinition(name: "wrap", parameters: ["x"], body: "uint(x,8)+1")])
        XCTAssertEqual("0xF0", try SheetEvaluationSession().evaluateWithFunctions("mask(-1)", library, []).results[0].display)
        XCTAssertEqual("0", try SheetEvaluationSession().evaluateWithFunctions("wrap(255)", library, []).results[0].display)
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "bad", parameters: [], body: "uint(1)")])) { XCTAssertTrue(IntegerTests.isFormat($0)) }
    }

    func testCancellationAndBudgetRemainShared() throws {
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("1 << 4095", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        let source = Array(repeating: "uint(-1,4096)", count: 1000).joined(separator: "+")
        XCTAssertNotNil(try SheetEvaluator.evaluate(source)[0].error)
    }
}
