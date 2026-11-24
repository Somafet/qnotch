import AppKit
import CalculatorEngine

/// What the rates button and menu say (Windows CalculatorSurface.Currencies), as pure functions of the cache and the
/// sheet's requests, so they are tested without a store.
enum CalculatorRateText {
    struct Snapshot: Equatable {
        let isMonthly: Bool
        let asOf: CalculatorDay
    }

    /// The button's text: what the sheet in front converts with, or the cache's state.
    static func status(downloading: Bool, warning: String?, uses: Bool, requests: [CalculatorDay?], latest: Snapshot?,
                       historical: [CalculatorDay: Snapshot], today: CalculatorDay) -> String {
        if downloading { return CalculatorText.downloadingRates }
        if warning?.contains("cache save failed") == true { return latest?.isMonthly == true ? CalculatorText.euNotSaved : CalculatorText.ecbNotSaved }
        if uses, !requests.isEmpty {
            let requested = requests.map { day in day.map { historical[$0] } ?? latest }
            if requested.contains(where: { $0 == nil }) {
                return requests.allSatisfy { $0 != nil } ? CalculatorText.historyUnavailable : CalculatorText.ratesUnavailable
            }
            if requests.allSatisfy({ $0 != nil }) {
                var dates: [CalculatorDay] = []
                for snapshot in requested.compactMap({ $0 }) where !dates.contains(snapshot.asOf) { dates.append(snapshot.asOf) }
                let monthly = requested[0]?.isMonthly == true
                if dates.count != 1 { return monthly ? CalculatorText.euMultiple : CalculatorText.ecbMultiple }
                return monthly ? CalculatorText.euDate(dates[0].description) : CalculatorText.ecbDate(dates[0].description)
            }
            if requests.contains(where: { $0 != nil }) { return latest?.isMonthly == true ? CalculatorText.euMixed : CalculatorText.ecbMixed }
        }
        guard let latest else { return historical.isEmpty ? CalculatorText.ratesUnavailable : CalculatorText.ecbHistoryCached }
        let stale = days(from: latest.asOf, to: today) > (latest.isMonthly ? 35 : 3)
        let asOf = shortDate(latest.asOf, monthly: latest.isMonthly)
        if latest.isMonthly { return stale ? CalculatorText.euStale(asOf) : CalculatorText.euDate(asOf) }
        return stale ? CalculatorText.ecbStale(asOf) : CalculatorText.ecbDate(asOf)
    }

    /// "24 Nov" for daily rates, "Nov 2026" for monthly ones, in the interface's language (English for now).
    static func shortDate(_ day: CalculatorDay, monthly: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = monthly ? "MMM yyyy" : "dd MMM"
        return formatter.string(from: date(day))
    }

    static func days(from start: CalculatorDay, to end: CalculatorDay) -> Int {
        Int(((date(end).timeIntervalSince1970 - date(start).timeIntervalSince1970) / 86_400).rounded())
    }

    private static func date(_ day: CalculatorDay) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date(timeIntervalSince1970: 0)
    }

    /// Today in the local zone.
    static func today(_ now: Date, zone: TimeZone = .current) -> CalculatorDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return CalculatorDay(year: parts.year ?? 2000, month: parts.month ?? 1, day: parts.day ?? 1)!
    }
}

/// The sheet's exchange rates (Windows CalculatorSurface.Currencies): the cache read on first need, downloads the user
/// asks for, and the optional daily download, scheduled only while the sheet is on screen and idle (C# CurrencyRefreshPolicy).
/// Snapshot, smoke, measure and demo runs never go online and read no cache. Main thread only, like the workspace that
/// owns it; the store itself is main-actor isolated.
final class CalculatorCurrencies {
    /// Where the conditions for an automatic download come from.
    struct Conditions {
        var enabled = false
        var visible = false
        var composing = false
    }

    private let directory: URL?
    let offline: Bool
    private(set) var store: CalculatorRateStore?
    /// What the latest evaluation of the sheet in front asked for.
    private(set) var uses = false
    private(set) var requests: [CalculatorDay?] = []
    private(set) var downloading = false
    private var downloadAutomatic = false
    private var loadTask: Task<Void, Never>?
    private var loadWaiters: [() -> Void] = []
    private var timer: DispatchWorkItem?
    private var closed = false
    /// The clock; tests move it.
    var now: () -> Date = Date.init
    /// The status, warning or menu changed.
    var changed: () -> Void = {}
    /// Downloaded rates replaced the cached ones: the sheet evaluates again.
    var ratesChanged: () -> Void = {}
    var conditions: () -> Conditions = { Conditions() }

    /// `directory` is `<data root>/calculator`, where `currency-rates.json` lives (the Windows file). Without one, or
    /// `offline`, nothing is read, written or downloaded.
    init(directory: URL?, offline: Bool) {
        self.directory = directory
        self.offline = offline || directory == nil
    }

    private func makeStore() -> CalculatorRateStore {
        if let store { return store }
        let directory = directory ?? FileManager.default.temporaryDirectory, offline = offline
        let made = onMain { CalculatorRateStore(directory: directory, offline: offline) }
        store = made
        return made
    }

    /// The store's state is read and changed on the main thread, where this runs.
    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        MainActor.assumeIsolated { UncheckedBox(body()) }.value
    }

    // MARK: The cache

    /// The cache has been read (offline runs have nothing to read).
    var isReady: Bool { offline || loaded }
    private var loaded: Bool { guard let store else { return false }; return onMain { store.loaded } }

    /// The rates for evaluation; nil until the cache is read.
    var rates: CalculatorRates? {
        guard let store, loaded else { return nil }
        return onMain { store.rates }
    }

    /// Reads the cache off the main thread once, then calls `done`. Offline at once.
    func ensureLoaded(_ done: @escaping () -> Void) {
        if closed { return }
        let store = makeStore()
        if isReady { return done() }
        loadWaiters.append(done)
        guard loadTask == nil else { return }
        loadTask = Task { @MainActor [weak self] in
            await store.load()
            guard let self, !self.closed else { return }
            self.loadTask = nil
            let waiters = self.loadWaiters
            self.loadWaiters.removeAll()
            self.changed()
            waiters.forEach { $0() }
        }
    }

    // MARK: The sheet in front

    /// A finished evaluation: what it converts with decides the button and the schedule.
    func adopt(uses: Bool, requests: [CalculatorDay?]) {
        let changedRequests = uses != self.uses || requests != self.requests
        self.uses = uses
        self.requests = requests
        if uses { _ = makeStore() }
        if changedRequests { changed() }
        refreshSchedule()
    }

    /// Typing or composing: an automatic download stops until the sheet settles again.
    func editing() { stopSchedule(cancelAutomatic: true) }

    /// The panel hides all the time: a download the user asked for keeps going, only the automatic one stops.
    func visibilityChanged(_ visible: Bool) {
        if visible { refreshSchedule() } else { stopSchedule(cancelAutomatic: true) }
    }

    /// The automatic preference changed, or the clock did.
    func preferencesChanged(automatic: Bool) {
        if !automatic { stopSchedule(cancelAutomatic: true) }
        refreshSchedule()
    }

    // MARK: What the menu shows

    private var storeWarning: String? { guard let store else { return nil }; return onMain { store.warning } }
    var warning: String? { downloading ? nil : storeWarning }
    var monthlyRoute: Bool { guard let store else { return false }; return onMain { store.monthlyRoute } }
    var latest: CalculatorRateSnapshotInfo? { guard let store else { return nil }; return onMain { store.latest } }

    var status: String {
        var latest: CalculatorRateText.Snapshot?, historical: [CalculatorDay: CalculatorRateText.Snapshot] = [:]
        if let store {
            latest = onMain { store.latest }.map { CalculatorRateText.Snapshot(isMonthly: $0.isMonthly, asOf: $0.asOf) }
            historical = onMain { store.historical }.mapValues { CalculatorRateText.Snapshot(isMonthly: $0.isMonthly, asOf: $0.asOf) }
        }
        return CalculatorRateText.status(downloading: downloading, warning: storeWarning, uses: uses, requests: requests, latest: latest,
                                         historical: historical, today: CalculatorRateText.today(now()))
    }

    /// The button's tooltip: the last problem, then where the rates come from.
    var tip: String {
        (warning.map { $0 + "\n" } ?? "") + (monthlyRoute ? CalculatorText.ratesTipMonthly : CalculatorText.ratesTip)
    }

    /// Dates the sheet asks for that the cache lacks and the current source covers.
    var missingDates: [CalculatorDay] {
        guard uses else { return [] }
        let store = makeStore(), requests = requests, today = CalculatorRateText.today(now())
        return onMain { store.missingDates(requests, today: today) }
    }

    var sourceURL: URL {
        let monthly = monthlyRoute
        return URL(string: onMain { monthly ? CalculatorRateStore.inforEuroSource : CalculatorRateStore.ecbSource })!
    }
    var sourceTip: String {
        let monthly = monthlyRoute
        return onMain { monthly ? CalculatorRateStore.inforEuroAttribution : CalculatorRateStore.ecbSource }
    }

    // MARK: Downloads

    /// Downloads the latest rates (`dates` [nil]) or the given dates, daily ECB or monthly EU rates.
    func download(_ dates: [CalculatorDay?], automatic: Bool, monthly: Bool) {
        guard !closed, !downloading, !dates.isEmpty, dates.count <= onMain({ CalculatorRateStore.maxHistoricalDates }) else { return }
        if automatic {
            let conditions = conditions()
            guard conditions.enabled, conditions.visible, !conditions.composing, uses, requests.contains(where: { $0 == nil }) else { return }
        }
        let store = makeStore()
        downloading = true
        downloadAutomatic = automatic
        stopSchedule()
        changed()
        Task { @MainActor [weak self] in
            let updated = await store.download(dates, automatic: automatic, monthly: monthly)
            guard let self, !self.closed else { return }
            self.downloading = false
            self.downloadAutomatic = false
            self.changed()
            if updated { self.ratesChanged() }
            self.refreshSchedule()
        }
    }

    func cancelDownload() {
        guard let store else { return }
        onMain { store.cancelDownload() }
    }

    /// QNotch quits or the Calculator is turned off: every download and timer stops.
    func shutdown() {
        closed = true
        stopSchedule()
        loadTask?.cancel()
        if let store { onMain { store.close() } }
    }

    // MARK: The automatic download

    /// One deadline for the next automatic download, only while it is allowed, the sheet is on screen and idle and
    /// needs the latest rates.
    func refreshSchedule() {
        timer?.cancel()
        timer = nil
        guard !closed, !downloading, uses, let store else { return }
        let conditions = conditions(), needsLatest = requests.contains(where: { $0 == nil }), now = now()
        guard let due = onMain({ store.nextAutomaticRefresh(enabled: conditions.enabled, visible: conditions.visible, composing: conditions.composing,
                                                            needsLatest: needsLatest, now: now) }) else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.download([nil], automatic: true, monthly: self.monthlyRoute)
        }
        timer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, due.timeIntervalSince(now)), execute: task)
    }

    private func stopSchedule(cancelAutomatic: Bool = false) {
        timer?.cancel()
        timer = nil
        if cancelAutomatic, downloading, downloadAutomatic, let store { onMain { store.cancelDownload(onlyAutomatic: true) } }
    }

    /// Whether an automatic download is waiting (tests and the hidden-idle smoke check).
    var hasSchedule: Bool { timer != nil }
}

/// Carries a value the main thread made across `MainActor.assumeIsolated`, which asks for Sendable results.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension CalculatorCurrencies {
    /// The rates menu, in Windows' order: status, problem, downloads, cancel, the automatic download, the source.
    func menuEntries(automatic: Bool) -> [RatesMenuCard.Entry] {
        typealias Entry = RatesMenuCard.Entry
        let idle = !downloading, monthly = monthlyRoute
        var entries = [Entry(id: "calculator-rates-status", title: status, kind: .note)]
        if let warning { entries.append(Entry(id: "calculator-rates-warning", title: warning, kind: .warning)) }
        entries.append(Entry(id: Self.latestID, title: CalculatorText.downloadLatest, tip: CalculatorText.downloadLatestTip, kind: .action, enabled: idle))
        entries.append(Entry(id: Self.monthlyID, title: CalculatorText.downloadMonthly, tip: CalculatorText.downloadMonthlyTip, kind: .action, enabled: idle))
        let missing = missingDates
        if !missing.isEmpty {
            entries.append(Entry(id: Self.historyID, title: CalculatorText.downloadHistory(missing.count),
                                 tip: CalculatorText.downloadHistoryTip(missing.map(\.description).joined(separator: ", ")), kind: .action, enabled: idle))
        }
        if downloading { entries.append(Entry(id: Self.cancelID, title: CalculatorText.cancelDownload, kind: .action)) }
        entries.append(Entry(id: Self.automaticID, title: CalculatorText.autoRates, tip: monthly ? CalculatorText.autoRatesTipMonthly : CalculatorText.autoRatesTip,
                             kind: .check(automatic)))
        entries.append(Entry(id: Self.sourceID, title: monthly ? CalculatorText.rateSourceMonthly : CalculatorText.rateSource, tip: sourceTip, kind: .link))
        return entries
    }

    static let latestID = "calculator-rates-latest", monthlyID = "calculator-rates-monthly", historyID = "calculator-rates-history"
    static let cancelID = "calculator-rates-cancel", automaticID = "calculator-rates-auto", sourceID = "calculator-rates-source"

    /// Runs a menu entry or a Settings button by its id; false for the source link, which the caller opens.
    @discardableResult
    func perform(_ id: String, workspace: CalculatorWorkspace) -> Bool {
        switch id {
        case Self.latestID: download([nil], automatic: false, monthly: false)
        case Self.monthlyID: download([nil], automatic: false, monthly: true)
        case Self.historyID: let route = monthlyRoute; download(missingDates.map { Optional($0) }, automatic: false, monthly: route)
        case Self.cancelID: cancelDownload()
        case Self.automaticID: workspace.updatePreferences { $0.autoCurrencyRates.toggle() }
        default: return false
        }
        return true
    }

    /// Opens the rate source in the browser; diagnostic runs never launch one.
    func openSource() {
        guard !Runtime.diagnostics else { return }
        NSWorkspace.shared.open(sourceURL)
    }
}
