import XCTest
import ObjectiveC

/// Runs last (XCTest orders classes by name) and writes how many xUnit-equivalent cases each test class ran:
/// theory rows and fixture cases count one each (CaseCounter), every other executed test method one.
final class ZZCaseCountReport: XCTestCase {
    func testWriteCaseCounts() throws {
        var totals: [String: Int] = [:]
        // Only this bundle's classes: enumerating every runtime class from Swift can message classes that trap.
        guard let image = Bundle(for: ZZCaseCountReport.self).executablePath else { return }
        var count: UInt32 = 0
        guard let names = objc_copyClassNamesForImage(image, &count) else { return }
        for index in 0..<Int(count) {
            let qualified = String(cString: names[index])
            guard let type = NSClassFromString(qualified), class_getSuperclass(type) == XCTestCase.self else { continue }
            let name = qualified.components(separatedBy: ".").last ?? qualified
            if name == "ZZCaseCountReport" { continue }
            var methodCount: UInt32 = 0
            guard let methods = class_copyMethodList(type, &methodCount) else { continue }
            let rows = CaseCounter.rows(for: name)
            var total = 0
            for m in 0..<Int(methodCount) {
                var selector = NSStringFromSelector(method_getName(methods[m]))
                // A throwing test is exported as testNameAndReturnError:.
                if selector.hasSuffix("AndReturnError:") { selector = String(selector.dropLast("AndReturnError:".count)) }
                guard selector.hasPrefix("test"), !selector.contains(":") else { continue }
                // Swift records rows under the method name with "()" (#function).
                total += rows[selector + "()"] ?? 1
            }
            free(methods)
            totals[name] = total
        }
        free(names)
        let url = Fixtures.repositoryRoot.appendingPathComponent("src/QNotch.Mac/Calculator/.build/calculator-case-counts.json")
        let data = try JSONSerialization.data(withJSONObject: totals, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
