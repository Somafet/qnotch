import Foundation

/// A deadline is the source of truth. Refreshes never decrement a counter.
public struct Countdown {
    public private(set) var duration: TimeInterval
    public private(set) var remaining: TimeInterval
    public private(set) var deadline: Date?
    public private(set) var finished = false

    public init(duration: TimeInterval) {
        self.duration = max(1, duration)
        remaining = self.duration
    }

    public var isRunning: Bool { deadline != nil }

    public func secondsLeft(at now: Date) -> TimeInterval {
        max(0, deadline.map { $0.timeIntervalSince(now) } ?? remaining)
    }

    public mutating func toggle(at now: Date) {
        if deadline != nil {
            remaining = secondsLeft(at: now)
            deadline = nil
        } else {
            if remaining <= 0 { remaining = duration }
            finished = false
            deadline = now.addingTimeInterval(remaining)
        }
    }

    public mutating func reset(duration: TimeInterval? = nil) {
        if let duration { self.duration = max(1, duration) }
        remaining = self.duration
        deadline = nil
        finished = false
    }

    @discardableResult public mutating func refresh(at now: Date) -> Bool {
        guard deadline != nil, secondsLeft(at: now) <= 0 else { return false }
        deadline = nil
        remaining = 0
        finished = true
        return true
    }

    /// Wakes just after the shown text goes stale. Visible content shows seconds. The collapsed
    /// pill shows whole minutes ("24m") and switches to seconds only for the final minute.
    public func nextWake(at now: Date, visible: Bool) -> TimeInterval? {
        guard isRunning else { return nil }
        let left = secondsLeft(at: now)
        guard left > 0 else { return 0.01 }
        let unit: TimeInterval = visible || left <= 60 ? 1 : 60
        let shown = ceil(left / unit)
        return max(0.01, left - (shown - 1) * unit)
    }

    public func text(at now: Date) -> String {
        let seconds = Int(ceil(secondsLeft(at: now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Compact status text: minutes while more than one remains and the timer runs, otherwise m:ss.
    public func shortText(at now: Date) -> String {
        let left = secondsLeft(at: now)
        guard isRunning, left > 60 else { return text(at: now) }
        return "\(Int(ceil(left / 60)))m"
    }

    public func progress(at now: Date) -> Double {
        min(1, max(0, secondsLeft(at: now) / duration))
    }
}
