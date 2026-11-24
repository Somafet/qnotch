import XCTest
@testable import CalculatorEngine

/// An in-memory HTTP layer for the rate clients (C# tests use an HttpMessageHandler). Never touches the network.
final class FakeRateTransport: CurrencyRateTransport {
    private let respond: (URL, CancellationToken) throws -> CurrencyRateHTTPResponse
    private(set) var requests: [(url: URL, accept: String)] = []
    init(_ respond: @escaping (URL, CancellationToken) throws -> CurrencyRateHTTPResponse) { self.respond = respond }
    func get(_ url: URL, accept: String, token: CancellationToken) async throws -> CurrencyRateHTTPResponse {
        requests.append((url, accept)); return try respond(url, token)
    }
}

/// An async [Theory]: one row per element, counted like `theory`.
func asyncTheory<T>(_ rows: [T], file: StaticString = #filePath, line: UInt = #line, _ body: (T) async throws -> Void) async {
    for row in rows {
        do { try await body(row) } catch { XCTFail("\(row): \(error)", file: file, line: line) }
        CaseCounter.record(file: "\(file)")
    }
}

/// XCTAssertThrowsError for async expressions.
func assertThrowsAsync(_ expression: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line, _ check: (Error) -> Void = { _ in }) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) } catch { check(error) }
}

extension CalcError {
    /// C# InvalidDataException.
    var isInvalidData: Bool { if case .invalidData = self { return true }; return false }
    /// C# IOException.
    var isIO: Bool { if case .io = self { return true }; return false }
}
