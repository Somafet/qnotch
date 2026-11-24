import XCTest
@testable import CalculatorEngine

final class NetworkTests: XCTestCase {
    private func last(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> LineResult {
        let result = try SheetEvaluator.evaluate(source).last!
        XCTAssertNil(result.error, source, file: file, line: line); XCTAssertNotNil(result.value, source, file: file, line: line)
        return result
    }
    private func network(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> NetworkValue {
        try XCTUnwrap(try last(source, file: file, line: line).value, source, file: file, line: line).network
    }
    private static func isFormat(_ error: Error) -> Bool { (error as? CalcError)?.isFormat == true }

    func testIndependentIpAddressOracle() throws {
        let cases = try JSONNode.parse(try Fixtures.data("networks-v1.json")).property("cases").arrayItems()
        for row in cases {
            CaseCounter.record(file: #filePath)
            let source = try row.property("input").string() + "/" + String(try row.property("prefix").int())
            do {
                let result = try network(source); let info = try XCTUnwrap(result.subnet, source)
                XCTAssertEqual(try row.property("cidr").string(), info.cidr, source)
                XCTAssertEqual(try row.property("first").string(), info.network.text, source)
                XCTAssertEqual(try row.property("last").string(), info.last.text, source)
                XCTAssertEqual(try row.property("mask").string(), info.mask.text, source)
                XCTAssertEqual(BigInt(try row.property("addresses").string()), info.addressCount, source)
                XCTAssertEqual(row["hosts"]?.stringValue, info.hostCount?.description, source)
                XCTAssertEqual(row["firstHost"]?.stringValue, info.firstHost?.text, source)
                XCTAssertEqual(row["lastHost"]?.stringValue, info.lastHost?.text, source)
                XCTAssertEqual(row["broadcast"]?.stringValue, info.broadcast?.text, source)
                XCTAssertEqual(result, try network(try result.copyText), source)
                XCTAssertEqual(info.mask.text, try last("netmask(\(info.prefix),\(try row.property("family").int()))").display, source)
                let reversed = try network(info.mask.text + " in cidr")
                XCTAssertEqual(info.prefix, reversed.prefix, source); XCTAssertEqual(reversed, try network(try reversed.copyText), source)
                for check in try row.property("membership").arrayItems() {
                    let member = try network(try check.property("address").string() + " in (" + source + ")")
                    XCTAssertEqual(try check.property("member").bool(), member.isMember, source)
                    XCTAssertEqual(member, try network(try member.copyText), source)
                }
            } catch { XCTFail("\(source): \(error)") }
        }
    }

    func testPublishedExamplesCanonicalFormsAndInteroperability() throws {
        try theory([("192.168.1.0/24", "192.168.1.0 – 192.168.1.255"), ("10.0.0.5 in 10.0.0.0/8", "yes"), ("11.0.0.5 in 10.0.0.0/8", "no"), ("/24 mask", "255.255.255.0"),
                    ("255.255.255.0 in cidr", "/24"), ("192.168.1.17/24", "192.168.1.0 – 192.168.1.255"), ("hostcount(192.0.2.0/30)", "2"), ("hostcount(192.0.2.0/31)", "2"),
                    ("hostcount(192.0.2.1/32)", "1"), ("ipcount(::/0)", "340282366920938463463374607431768211456"), ("/64 ipv6 mask", "ffff:ffff:ffff:ffff::"),
                    ("ffff:ffff:ffff:ffff:: in cidr", "/64"), ("2001:DB8:0:0:0:0:0:1", "2001:db8::1"), ("2001:0:0:1:0:0:0:1", "2001:0:0:1::1"),
                    ("2001:0:0:1:0:0:1:1", "2001::1:0:0:1:1"), ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"), ("::ffff:192.0.2.1", "::ffff:c000:201"),
                    ("192.0.2.1 in ::ffff:c000:200/120", "no"), ("::ffff:192.0.2.1 in ::ffff:c000:200/120", "yes"), ("firsthost(192.0.2.0/31)", "192.0.2.0"),
                    ("lasthost(192.0.2.1/32)", "192.0.2.1"), ("broadcast(192.0.2.17/28)", "192.0.2.31"), ("network(192.0.2.17/28)", "192.0.2.16"),
                    ("lastip(::/0)", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), ("firstip(2001:db8::1/64)", "2001:db8::"), ("192.0.2.17/28 in mask", "255.255.255.240"),
                    ("192.0.2.17/28 in cidr", "/28"), ("net=192.0.2.0/24\naddr=192.0.2.42\naddr in net", "yes"), ("Subnet 192.0.2.1/32", "192.0.2.1 – 192.0.2.1"),
                    ("width=24\naddr=192.0.2.1\naddr/width", "192.0.2.0 – 192.0.2.255"), ("net=192.0.2.0/24\nfirstip(net) in net", "yes"), ("10:00:30", "10:00:30"),
                    ("2027-03-01", "2027-03-01"), ("prefix=255.255.255.0 in cidr\nsubnet(192.0.2.17,prefix)", "192.0.2.0 – 192.0.2.255"),
                    ("192.0.2.17 / (255.255.255.0 in cidr)", "192.0.2.0 – 192.0.2.255"), ("netmask(cidr(255.255.255.0),4)", "255.255.255.0"),
                    ("cidr(cidr(255.255.255.0))", "/24"), ("m=7\n10 cm in m", "0.1 m"), ("1/2", "0.5"), ("1.25+2.75", "4"), ("1 << 4", "16")]) { source, expected in
            XCTAssertEqual(expected, try last(source).display, source)
        }
    }

    func testInvalidNetworksAndTypedArithmeticFail() throws {
        try theory(["256.0.0.1", "01.2.3.4", "0x1.2.3.4", "1.2.3.4abc", "1.2.3.4.5",
                    "192.0.2.1/33", "192.0.2.1/-1", "192.0.2.1/1.5", "192.0.2.1/24%",
                    "2001:db8::1/129", "2001:db8:::1", "fe80::1%2", "[::1]:80",
                    "::ffff:192.000.2.1", "2001:db8::xyz", "2001:db8::1::2",
                    "255.0.255.0 in cidr", "::1 in cidr", "/33 mask", "/129 ipv6 mask",
                    "netmask(24,5)", "subnet(1,24)", "contains(192.0.2.0/24,1)", "192.0.2.1 in 192.0.2.0",
                    "hostcount(::/64)", "firsthost(::/127)", "broadcast(::/0)", "broadcast(192.0.2.0/31)",
                    "192.0.2.1+1", "192.0.2.0/24+1", "1/192.0.2.1", "192.0.2.1 << 1",
                    "subnet(::1,cidr(255.255.255.0))", "netmask(cidr(255.255.255.0),6)",
                    "cidr()", "netmask(24)", "subnet(192.0.2.1)", "contains(192.0.2.0/24)"]) { source in
            XCTAssertNotNil(try SheetEvaluator.evaluate(source).last!.error, source)
        }
    }

    func testFactsKeepHostModelAndNormalizationExplicit() throws {
        let ipv4 = try network("192.0.2.17/28")
        XCTAssertTrue(ipv4.details.contains("host bits normalized")); XCTAssertTrue(ipv4.details.contains("Reserved/special addresses are not filtered"))
        XCTAssertTrue(try network("192.0.2.0/31").details.contains("RFC 3021"))
        XCTAssertTrue(try network("::/0").details.contains("no broadcast"))
        XCTAssertNil(try network("::/0").subnet!.hostCount)
    }

    func testSavedFunctionsAndIncrementalMembershipPreserveTypes() throws {
        let library = try FunctionLibrary([FunctionDefinition(name: "office", parameters: ["x"], body: "x in 192.0.2.0/24"), FunctionDefinition(name: "block", parameters: ["p"], body: "subnet(192.0.2.17,p)")])
        let result = try SheetEvaluationSession().evaluateWithFunctions("office(192.0.2.1)\nblock(28)", library, [])
        XCTAssertEqual("yes", result.results[0].display); XCTAssertEqual("192.0.2.16 – 192.0.2.31", result.results[1].display)
        XCTAssertThrowsError(try FunctionLibrary([FunctionDefinition(name: "bad", parameters: [], body: "netmask(24)")])) { XCTAssertTrue(NetworkTests.isFormat($0)) }
        let session = SheetEvaluationSession(); _ = try session.evaluate("n=192.0.2.0/24\na=192.0.2.1\na in n\n2+2")
        let changed = try session.evaluate("n=192.0.3.0/24\na=192.0.2.1\na in n\n2+2")
        XCTAssertEqual("no", changed[2].display); XCTAssertEqual(1, session.lastStatistics.parsedLines); XCTAssertTrue(session.lastStatistics.reusedResults > 0)
    }

    func testCountsAreBoundedAndCultureIndependentWithoutEnumeratingHosts() throws {
        // C# switches CurrentCulture to ar-SA here; the Swift engine never reads a locale, so the same assertions run as is.
        XCTAssertEqual("340282366920938463463374607431768211456", try last("ipcount(::/0)").display); XCTAssertEqual("255.255.255.0", try last("/24 mask").display)
        let cancellation = CancellationToken(); cancellation.cancel()
        XCTAssertThrowsError(try SheetEvaluator.evaluate("::/0", cancellation)) { XCTAssertEqual($0 as? CalcError, .cancelled) }
        XCTAssertNotNil(try SheetEvaluator.evaluate(String(repeating: "f", count: 130) + "::1")[0].error)
    }
}
