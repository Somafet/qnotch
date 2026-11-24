import Foundation

/// Result of isprime or factor. It reads as a verdict or a product and is not a number. `isProven` is false above the deterministic bound.
struct PrimeValue: Hashable, CustomStringConvertible {
    let number: BigInt
    let isPrime: Bool
    let isProven: Bool
    let text: String
    init(_ number: BigInt, _ isPrime: Bool, _ isProven: Bool, _ display: String) { self.number = number; self.isPrime = isPrime; self.isProven = isProven; text = display }
    // Throwing like the other SheetValue payloads so the shared display switch reads alike; it never throws.
    var display: String { get throws { text } }
    var copyText: String { get throws { text } }
    var description: String { text }
}
