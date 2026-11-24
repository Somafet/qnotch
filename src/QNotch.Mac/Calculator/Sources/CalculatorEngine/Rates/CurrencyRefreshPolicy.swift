import Foundation

/// When the host may download the latest rates: only with consent, while visible, idle and needed; at most daily.
/// Durations are .NET ticks (100 ns), as C# TimeSpan.
enum CurrencyRefreshPolicy {
    static func next(_ enabled: Bool, _ visible: Bool, _ composing: Bool, _ needsLatest: Bool, _ busy: Bool,
                     _ snapshot: CurrencyRateSnapshot?, _ now: Instant, _ retryNotBefore: Instant?) -> Instant? {
        if !enabled || !visible || composing || !needsLatest || busy { return nil }
        var next = snapshot == nil || snapshot!.retrievedAt > now ? now : Instant(unixTicks: snapshot!.retrievedAt.unixTicks + Ticks.perDay)
        if let retry = retryNotBefore, retry > next { next = retry }
        return next < now ? now : next
    }
    /// The earliest retry after a failed download: the provider's advice, clamped to 15 minutes…1 day.
    static func failed(_ now: Instant, _ retryAfterTicks: Int64? = nil) -> Instant {
        var delay = retryAfterTicks ?? 15 * Ticks.perMinute
        if delay < 15 * Ticks.perMinute { delay = 15 * Ticks.perMinute }
        if delay > Ticks.perDay { delay = Ticks.perDay }
        return Instant(unixTicks: now.unixTicks + delay)
    }
}
