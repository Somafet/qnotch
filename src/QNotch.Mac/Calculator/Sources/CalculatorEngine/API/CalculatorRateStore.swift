import Foundation

/// A Gregorian calendar day, for rate dates the app shows or asks for.
public struct CalculatorDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int
    public init?(year: Int, month: Int, day: Int) {
        guard DateOnly(year, month, day) != nil else { return nil }
        self.year = year; self.month = month; self.day = day
    }
    init(_ date: DateOnly) { let p = date.parts; year = p.year; month = p.month; day = p.day }
    var date: DateOnly { DateOnly(year, month, day)! }
    public static func < (a: CalculatorDay, b: CalculatorDay) -> Bool { a.date < b.date }
    /// yyyy-MM-dd.
    public var description: String { date.description }
}

/// One cached rate snapshot, as the rates menu describes it.
public struct CalculatorRateSnapshotInfo: Hashable, Sendable {
    /// "ECB via Frankfurter" or "EC InforEuro via Frankfurter".
    public let provider: String
    /// EU monthly accounting rates (InforEuro) rather than ECB daily reference rates.
    public let isMonthly: Bool
    public let asOf: CalculatorDay
    public let retrievedAt: Date
}

/// The sheet's exchange-rate cache and downloads (Windows CalculatorSurface.Currencies with CurrencyRateCache and
/// EcbRateConnection). The cache file is the same as Windows writes (`currency-rates.json` in the data folder).
/// Main-actor isolated, so its state only changes between the app's own events; cache reads and writes and the
/// downloads themselves run off the main thread.
@MainActor
public final class CalculatorRateStore {
    public static let ecbSource = EcbRateClient.source
    public static let inforEuroSource = InforEuroRateClient.source
    public static let inforEuroAttribution = InforEuroRateClient.attribution
    public static let maxHistoricalDates = CurrencyRateBook.maxHistoricalSnapshots

    private let cache: CurrencyRateCache
    private let offline: Bool
    private var connection: EcbRateConnection?
    private var download: CancellationToken?
    private(set) var book = CurrencyRateBook.empty
    public private(set) var loaded = false
    /// Why the last load or download did not go as planned ("…; cached data retained"), or nil.
    public private(set) var warning: String?
    /// After a failed download, no automatic retry before this.
    public private(set) var retryNotBefore: Date?
    public private(set) var isDownloading = false
    public private(set) var downloadIsAutomatic = false

    /// `offline` (snapshot, smoke and demo runs) never goes online.
    public init(directory: URL, offline: Bool = false) {
        cache = CurrencyRateCache(directory.path)
        self.offline = offline
    }

    /// The rates for evaluation.
    public var rates: CalculatorRates { CalculatorRates(book) }
    public var latest: CalculatorRateSnapshotInfo? { book.latest.map(CalculatorRateStore.info) }
    public var historical: [CalculatorDay: CalculatorRateSnapshotInfo] {
        Dictionary(uniqueKeysWithValues: book.historical.map { (CalculatorDay($0.key), CalculatorRateStore.info($0.value)) })
    }
    /// The latest snapshot is the EU monthly route.
    public var monthlyRoute: Bool { book.latest?.isMonthly == true }
    private static func info(_ snapshot: CurrencyRateSnapshot) -> CalculatorRateSnapshotInfo {
        CalculatorRateSnapshotInfo(provider: snapshot.provider, isMonthly: snapshot.isMonthly, asOf: CalculatorDay(snapshot.asOf),
                                   retrievedAt: Date(timeIntervalSince1970: Double(snapshot.retrievedAt.unixTicks) / Double(Ticks.perSecond)))
    }
    /// Whether the latest snapshot is older than its provider's freshness (3 days daily, 35 days monthly) on `today`.
    public func latestIsStale(today: CalculatorDay) -> Bool {
        guard let latest = book.latest else { return false }
        return today.date.dayNumber - latest.asOf.dayNumber > (latest.isMonthly ? 35 : 3)
    }

    /// Reads the cache once, off the main thread. Later calls do nothing.
    public func load() async {
        if loaded { return }
        let cache = self.cache, offline = self.offline
        let result: (CurrencyRateBook, String?) = await Task.detached(priority: .utility) {
            if offline { return (CurrencyRateBook.empty, nil) }
            do { let load = try cache.load(); return (load.book, load.warning) }
            catch { return (CurrencyRateBook.empty, "Rates unavailable; cached data retained") }
        }.value
        if loaded { return }
        book = result.0; warning = result.1; loaded = true
    }

    /// Dates a sheet asks for that the cache lacks and the current source covers (up to `today`).
    public func missingDates(_ requests: [CalculatorDay?], today: CalculatorDay) -> [CalculatorDay] {
        let first = monthlyRoute ? InforEuroRateClient.firstDate : EcbRateClient.firstDate
        var seen = Set<CalculatorDay>(), result: [CalculatorDay] = []
        for case let day? in requests where book.historical[day.date] == nil && day.date >= first && day.date <= today.date && seen.insert(day).inserted { result.append(day) }
        return result
    }

    /// When an automatic download of the latest rates is due (C# CurrencyRefreshPolicy), or nil.
    public func nextAutomaticRefresh(enabled: Bool, visible: Bool, composing: Bool, needsLatest: Bool, now: Date = Date()) -> Date? {
        guard let due = CurrencyRefreshPolicy.next(enabled, visible, composing, needsLatest, isDownloading, book.latest, CalculatorRateStore.instant(now),
                                                   retryNotBefore.map(CalculatorRateStore.instant)) else { return nil }
        return Date(timeIntervalSince1970: Double(due.unixTicks) / Double(Ticks.perSecond))
    }

    /// Downloads the given dates (nil = latest) from ECB daily or EU monthly rates, then saves the cache.
    /// Returns true when the rates changed. A failure leaves the cached rates and sets `warning`.
    @discardableResult
    public func download(_ dates: [CalculatorDay?], automatic: Bool, monthly: Bool) async -> Bool {
        if isDownloading || dates.isEmpty || dates.count > CurrencyRateBook.maxHistoricalSnapshots { return false }
        let token = CancellationToken(); download = token
        isDownloading = true; downloadIsAutomatic = automatic
        retryNotBefore = CalculatorRateStore.date(CurrencyRefreshPolicy.failed(CalculatorRateStore.instant(Date())))
        var completed = 0
        await load()
        var book = self.book
        let timeout = Task { try await Task.sleep(nanoseconds: 120_000_000_000); token.cancel() }
        defer { timeout.cancel() }
        do {
            if offline { throw CalcError.io("Demo runs never go online") }
            // Closed while the cache loaded: no connection, so no URLSession that nothing would invalidate.
            if token.isCancellationRequested { throw CalcError.cancelled }
            if connection == nil { connection = EcbRateConnection() }
            var seen = Set<DateOnlyKey>()
            for day in dates where seen.insert(DateOnlyKey(date: day?.date)).inserted {
                let now = Date(), offset = TimeZone.current.secondsFromGMT(for: now)
                let snapshot = monthly ? try await connection!.fetchInforEuro(day?.date, now: CalculatorRateStore.instant(now), utcOffsetSeconds: offset, token: token)
                                       : try await connection!.fetch(day?.date, now: CalculatorRateStore.instant(now), utcOffsetSeconds: offset, token: token)
                var historical = book.historical
                if let requested = day?.date {
                    if historical[requested] == nil && historical.count >= CurrencyRateBook.maxHistoricalSnapshots,
                       let oldest = historical.min(by: { $0.value.retrievedAt < $1.value.retrievedAt })?.key { historical[oldest] = nil }
                    historical[requested] = snapshot
                }
                book = try CurrencyRateBook(day == nil ? snapshot : book.latest, historical.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                completed += 1
            }
            warning = nil; retryNotBefore = nil
        } catch CalcError.cancelled {
            warning = "Rate download canceled or timed out; cached data retained"
        } catch let error as CurrencyRateHttpError {
            warning = "Rate provider HTTP \(error.status); cached data retained"
            retryNotBefore = CalculatorRateStore.date(CurrencyRefreshPolicy.failed(CalculatorRateStore.instant(Date()), error.retryAfterTicks))
        } catch {
            warning = "Rates unavailable; cached data retained"
        }
        if completed > 0 {
            self.book = book
            let cache = self.cache
            let saved = await Task.detached(priority: .utility) { (try? cache.save(book)) != nil }.value
            if !saved { warning = "Downloaded rates in memory; cache save failed" }
        }
        download = nil; isDownloading = false; downloadIsAutomatic = false
        return completed > 0
    }
    /// Cancels a running download (C# currencyDownload.Cancel()).
    public func cancelDownload(onlyAutomatic: Bool = false) {
        if !onlyAutomatic || downloadIsAutomatic { download?.cancel() }
    }
    public func close() { download?.cancel(); connection?.close(); connection = nil }

    private static func instant(_ date: Date) -> Instant { Instant(unixTicks: Int64((date.timeIntervalSince1970 * Double(Ticks.perSecond)).rounded(.down))) }
    private static func date(_ instant: Instant) -> Date { Date(timeIntervalSince1970: Double(instant.unixTicks) / Double(Ticks.perSecond)) }
}
