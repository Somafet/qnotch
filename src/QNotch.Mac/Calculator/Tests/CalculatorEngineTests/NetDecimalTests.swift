import XCTest
@testable import CalculatorEngine

/// NetDecimal against System.Decimal: each row is an operation and the .NET 10 result's ToString (or the
/// formatted text), produced with System.Decimal by a throwaway .NET console project. The full run used
/// while porting compared 3,564 such operations (edge cases, random +, −, ×, ÷, rounding and formatting).
final class NetDecimalTests: XCTestCase {
    private static let vectors: [(String, String)] = [
            ("/ 1 3", "0.3333333333333333333333333333"),
            ("/ 2 3", "0.6666666666666666666666666667"),
            ("/ 10 3", "3.3333333333333333333333333333"),
            ("/ 20 3", "6.6666666666666666666666666667"),
            ("/ 100 3", "33.333333333333333333333333333"),
            ("/ 1000 3", "333.33333333333333333333333333"),
            ("/ 80 7", "11.428571428571428571428571429"),
            ("/ 9 7", "1.2857142857142857142857142857"),
            ("/ 1.00 2", "0.50"),
            ("/ 1 0.5", "2"),
            ("/ 100 0.5", "200"),
            ("/ 1.0 4", "0.25"),
            ("/ 2.50 0.5", "5.0"),
            ("/ 1.45 100", "0.0145"),
            ("/ 2.9 2", "1.45"),
            ("/ 600001 100", "6000.01"),
            ("/ 600000 100", "6000"),
            ("/ 69750 12", "5812.5"),
            ("/ 101400 12", "8450"),
            ("/ 1 1", "1"),
            ("/ 0 5", "0"),
            ("/ 0.00 5", "0.00"),
            ("/ 1 0.3", "3.3333333333333333333333333333"),
            ("/ 79228162514264337593543950335 1", "79228162514264337593543950335"),
            ("/ 79228162514264337593543950335 10", "7922816251426433759354395033.5"),
            ("/ 7922816251426433759354395033 3", "2640938750475477919784798344.3"),
            ("/ 1 79228162514264337593543950335", "0"),
            ("* 1.5 1.5", "2.25"),
            ("* 0.0000000000000001 0.0000000000000001", "0.0000000000000000000000000000"),
            ("* 79228162514264337593543950335 1.0", "79228162514264337593543950335"),
            ("+ 0.1 0.20", "0.30"),
            ("- 5 5", "0"),
            ("- -5 -5", "0"),
            ("- 0.10 0.1", "0.00"),
            ("trunc 12.99", "12"),
            ("trunc -12.99", "-12"),
            ("round 2.5 0", "2"),
            ("round 3.5 0", "4"),
            ("round 2.45 1", "2.4"),
            ("roundaway 2.5 0", "3"),
            ("roundaway 2.45 1", "2.5"),
            ("f2 1", "1.00"),
            ("f2 0.005", "0.01"),
            ("f2 0.015", "0.02"),
            ("f2 12.345", "12.35"),
            ("f1 21.25", "21.3"),
            ("f1 21.15", "21.2"),
            ("f1 0.05", "0.1"),
            ("f2 -0.005", "-0.01"),
            ("parse 0.50", "0.50"),
            ("parse 20.000", "20.000"),
            ("parse 1.", "1"),
            ("parse .5", "0.5"),
            ("parse .", "fail"),
            ("parse 1.2.3", "fail"),
            ("parse 007", "7"),
            ("parse 2.9", "2.9"),
            ("parse 12345678901234567890123456789.5", "12345678901234567890123456790"),
            ("parse 0.12345678901234567890123456789", "0.1234567890123456789012345679"),
            ("cmp 1.0 1.00", "0"),
            ("cmp 1 2", "-1"),
            ("long 12.9", "12"),
            ("long -12.9", "-12"),
            ("/ 879.7323216 200", "4.398661608"),
            ("/ 55 14.86", "3.7012113055181695827725437416"),
            ("+ 95.51 6809848565", "6809848660.51"),
            ("trunc 9", "9"),
            ("trunc 9399634.0950520", "9399634"),
            ("- 397036.7 14816", "382220.7"),
            ("roundaway 0.00000000 3", "0.000"),
            ("f1 0.00267", "0.0"),
            ("f2 0.00046", "0.00"),
            ("roundaway 21.86093074 2", "21.86"),
            ("* 4.15791814 994.51", "4135.0911694114"),
            ("- 9.51664293 0.000822", "9.51582093"),
            ("/ 59796.87 1", "59796.87"),
            ("round 21 4", "21"),
            ("roundaway 62637440919 4", "62637440919"),
            ("trunc 601451.719543", "601451"),
            ("/ 86563505368 753576.743", "114870.19228246007586781377089"),
            ("/ 0.19387719 100", "0.0019387719"),
            ("* 9.54020 1.15039", "10.9749506780"),
            ("f1 903788", "903788.0"),
            ("f2 62.411", "62.41"),
            ("* 0.0007 0.00060921", "0.000000426447"),
            ("f1 970408187.8", "970408187.8"),
            ("roundaway 908.245826 4", "908.2458"),
            ("/ 5649.90814657 653.508151", "8.645505244157237757238011864"),
            ("+ 9881042416.8431 870.0", "9881043286.8431"),
            ("/ 514425692 100", "5144256.92"),
            ("trunc 7.20849", "7"),
            ("f1 77307.50", "77307.5"),
            ("round 0.002 0", "0"),
            ("- 0.009 0.095704", "-0.086704"),
            ("round 0.0000803 5", "0.00008"),
            ("/ 46 0.0366", "1256.8306010928961748633879781"),
            ("/ 25479342.08 12.0", "2123278.5066666666666666666667"),
            ("+ 9835.5959128 27483021.627", "27492857.2229128"),
            ("trunc 597428112773", "597428112773"),
            ("/ 580565600 55143834", "10.528205202416647344470099776"),
            ("/ 383743900 74608241", "5.143451914380343050843404819"),
            ("/ 987517500 38368445", "25.737751425683266548852839879"),
            ("/ 619024100 55736044", "11.106351573857663812666718865"),
            ("/ 109525400 8167438", "13.410006907918982672412083202")]

    func testMatchesSystemDecimal() throws {
        func value(_ text: String) throws -> NetDecimal {
            let negative = text.hasPrefix("-")
            guard let parsed = NetDecimal.parse(negative ? String(text.dropFirst()) : text) else { throw CalcError.format("Bad vector " + text) }
            return negative ? -parsed : parsed
        }
        for (operation, expected) in NetDecimalTests.vectors {
            let p = operation.split(separator: " ").map(String.init)
            let actual: String
            switch p[0] {
            case "+": actual = (try value(p[1]) + value(p[2])).description
            case "-": actual = (try value(p[1]) - value(p[2])).description
            case "*": actual = (try value(p[1]) * value(p[2])).description
            case "/": actual = (try value(p[1]) / value(p[2])).description
            case "trunc": actual = try value(p[1]).truncated.description
            case "round": actual = try value(p[1]).rounded(Int(p[2])!).description
            case "roundaway": actual = try value(p[1]).rounded(Int(p[2])!, awayFromZero: true).description
            case "f2": actual = try value(p[1]).fixed(2)
            case "f1": actual = try value(p[1]).fixed(1)
            case "parse": actual = NetDecimal.parse(p[1])?.description ?? "fail"
            case "cmp": let x = try value(p[1]), y = try value(p[2]); actual = x < y ? "-1" : x == y ? "0" : "1"
            case "long": actual = String(try value(p[1]).int64)
            default: XCTFail(operation); continue
            }
            XCTAssertEqual(actual, expected, operation)
        }
        XCTAssertThrowsError(try NetDecimal(5) / NetDecimal.zero) { XCTAssertEqual($0 as? CalcError, .arithmetic(CalcError.divideByZeroMessage)) }
    }
}
