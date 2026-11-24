import XCTest
@testable import CalculatorEngine

final class DeveloperHelperTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> SheetValue {
        let result = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(result.error, source, file: file, line: line)
        return try XCTUnwrap(result.value, source, file: file, line: line)
    }
    private static func double(_ r: Rational) -> Double { r.numerator.toDouble() / r.denominator.toDouble() }

    func testIndependentStandardLibraryOracle() throws {
        let cases = try JSONNode.parse(try Fixtures.data("developer-helpers-v1.json")).property("cases").arrayItems()
        for row in cases {
            CaseCounter.record(file: #filePath)
            let source = try row.property("source").string()
            do {
                let value = try last(source)
                switch try row.property("kind").string() {
                case "permission":
                    XCTAssertEqual(try row.property("bits").int(), try value.permission.bits, source)
                    XCTAssertEqual(try row.property("symbolic").string(), try value.permission.symbolic, source)
                    XCTAssertEqual(try value.permission.bits, try last("chmod(\"" + (try value.permission.symbolic) + "\")").permission.bits, source)
                case "colour":
                    let rgb = try row.property("rgb").arrayItems().map { try $0.int() }
                    XCTAssertEqual(try Rational(rgb[0], 255), try value.colour.red, source)
                    XCTAssertEqual(try Rational(rgb[1], 255), try value.colour.green, source)
                    XCTAssertEqual(try Rational(rgb[2], 255), try value.colour.blue, source)
                    let hsl = try row.property("hsl").arrayItems().map { try $0.double() }
                    XCTAssertLessThanOrEqual(abs(DeveloperHelperTests.double(try value.colour.hue) - hsl[0]), 1e-10, source)
                    XCTAssertLessThanOrEqual(abs(DeveloperHelperTests.double(try value.colour.saturation) - hsl[1]), 1e-12, source)
                    XCTAssertLessThanOrEqual(abs(DeveloperHelperTests.double(try value.colour.lightness) - hsl[2]), 1e-12, source)
                case "hsl":
                    let expected = try row.property("rgb").arrayItems().map { try $0.double() }
                    let channels = [try value.colour.red, try value.colour.green, try value.colour.blue]
                    for i in 0..<3 { XCTAssertLessThanOrEqual(abs(DeveloperHelperTests.double(channels[i]) - expected[i]), 1e-12, source) }
                case "aspect": XCTAssertEqual(try Rational(try row.property("n").int(), try row.property("d").int()), try value.aspect.ratio, source)
                case "unicode":
                    XCTAssertEqual([try row.property("scalar").int()], try value.unicode.scalars, source)
                    XCTAssertEqual(try row.property("utf8").string(), TextArithmetic.hex(Array(try value.unicode.text.utf8)), source)
                    XCTAssertEqual(try row.property("utf16Units").int(), try value.unicode.text.netLength, source)
                default: break
                }
                XCTAssertEqual(value, try last(try value.copyText), source)
            } catch { XCTFail("\(source): \(error)") }
        }
    }

    func testPublishedExamplesAndConventions() throws {
        try theory([("#FF8800 in rgb", "rgb(255, 136, 0)"), ("#FF8800 in hsl", "hsl(32, 100%, 50%)"), ("chmod 755", "rwxr-xr-x"), ("1920x1080 aspect", "16:9"),
                    ("U+1F600", "😀 U+1F600"), ("hsl(-120,100%,50%) in hex", "#0000FF"), ("rgb(100%,0%,0%) in hex", "#FF0000"), ("#f008 in rgb", "rgba(255, 0, 0, 0.5333)"),
                    ("chmod(\"rwsr-Sr-t\")", "7745"), ("aspect(192 cm,1.08 m)", "16:9"), ("(16/9) in ratio", "16:9"), ("unicode(\"e\\u0301\")", "U+0065 U+0301"),
                    ("U=7\nU+1234", "1241"), ("a=#face\na in rgb", "rgba(255, 170, 204, 0.9333)")]) { source, expected in
            XCTAssertEqual(expected, try last(source).display, source)
        }
    }

    func testInvalidDomainsAndTypedArithmeticFail() throws {
        try theory(["rgb(-1,0,0)", "rgb(256,0,0)", "rgb(1,2,3,2)",
                    "hsl(1,101,50)", "hsl(1,50,-1)", "hsl(50%,50,50)",
                    "color(\"#12345\")", "color(\"#GGG\")", "rgb(1)",
                    "chmod 888", "chmod -1", "chmod 10000", "chmod u+x",
                    "chmod(\"rwqrwxrwx\")", "chmod(\"rwxrwxrws\")", "chmod(0x1000)",
                    "aspect(0,1)", "aspect(-1,1)", "aspect(1 m,2 s)",
                    "aspect(1%,2%)", "aspect(1 Celsius,2 Celsius)", "50% in ratio",
                    "U+D800", "U+DFFF", "U+110000", "codepoint(-1)",
                    "#fff in hex u8", "codepoint(50%)", "codepoint(0.5)", "unicode(\"\")", "unicode(1)",
                    "#fff+1", "chmod(755)+1", "U+1F600+1"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testTagsFunctionsReferencesAndExactCopies() throws {
        let lines = try SheetEvaluator.evaluate("# Heading\nc=#abc #palette\n2 #face\nc in hsl\nchmod(0o755)\nf(x)=rgb(x,0,0)\nf(128)")
        for line in lines { XCTAssertNil(line.error) }
        XCTAssertEqual("2", try last("2 #face\nsum #face").display)
        XCTAssertEqual(493, try lines[4].value!.permission.bits)
        XCTAssertEqual(try Rational(128, 255), try lines[lines.count - 1].value!.colour.red)
        let quantized = try last("rgb(0.5,0,0) in hex"); XCTAssertTrue(try quantized.display.hasPrefix("≈"))
        XCTAssertEqual("colour hex presentation", try SheetEvaluator.evaluate("rgb(0.5,0,0) in hex")[0].explanation.last!.operation)
        XCTAssertEqual(quantized, try last(try quantized.copyText))
        XCTAssertEqual(try last("rgb(0.5,0,0)"), try last("rgb(" + (try quantized.copyText) + ")"))
        XCTAssertEqual(try last("U+0000"), try last(try last("U+0000").copyText))
        XCTAssertEqual(0, try last("chr(0)").text.value.utf16.first)
    }

    func testSequenceBoundAndCancellation() throws {
        XCTAssertEqual(256, try last("unicode(text(\"" + String(repeating: "a", count: 256) + "\"))").unicode.scalars.count)
        XCTAssertNotNil(try SheetEvaluator.evaluate("unicode(text(\"" + String(repeating: "a", count: 257) + "\"))")[0].error)
        let cancel = CancellationToken(); cancel.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("#fff in rgb", cancel)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
    }
}
