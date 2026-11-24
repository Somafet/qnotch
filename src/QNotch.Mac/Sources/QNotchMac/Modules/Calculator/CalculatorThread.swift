import Foundation

/// A serial background thread with a main-thread-sized stack, for engine evaluations. A GCD worker has 512 KB of stack: a debug
/// build of the engine's evaluator needs more than that for one frame, and a release build is closer to it than we want on the
/// engine's deepest (64-level) expressions. The thread starts on first use and ends after a few idle seconds; while idle it
/// sleeps on a condition (no timer, no polling).
final class CalculatorThread: @unchecked Sendable {
    static let stackSize = 8 << 20
    private static let idleSeconds: TimeInterval = 10

    private let name: String
    private let quality: QualityOfService
    private let condition = NSCondition()
    private var work: [() -> Void] = []
    private var running = false

    init(name: String, quality: QualityOfService = .userInitiated) {
        self.name = name
        self.quality = quality
    }

    /// Runs `block` after everything queued before it, on this thread.
    func async(_ block: @escaping () -> Void) {
        condition.lock()
        work.append(block)
        if !running {
            running = true
            let thread = Thread { [self] in loop() }
            thread.name = name
            thread.stackSize = Self.stackSize
            thread.qualityOfService = quality
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while work.isEmpty {
                if !condition.wait(until: Date(timeIntervalSinceNow: Self.idleSeconds)), work.isEmpty {
                    running = false
                    condition.unlock()
                    return
                }
            }
            let next = work.removeFirst()
            condition.unlock()
            autoreleasepool { next() }
        }
    }
}
