import Foundation

/// The shared oracle fixtures in tests/fixtures/calculator, read by both the Windows and the Mac engine tests.
enum Fixtures {
    static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() } // Tests/CalculatorEngineTests/Fixtures.swift → repository root
        return url
    }()
    static let folder = repositoryRoot.appendingPathComponent("tests/fixtures/calculator")
    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func text(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
}
