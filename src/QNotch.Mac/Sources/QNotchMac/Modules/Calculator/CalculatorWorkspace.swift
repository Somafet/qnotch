import AppKit
import CalculatorEngine

/// Evaluates sheets off the main thread. A newer request cancels the one before it and only the newest
/// outcome is delivered, on the main thread; a sheet's session reuses its unchanged lines.
final class CalculatorEvaluator {
    enum Outcome { case done(CalculatorEvaluation), failed(String) }

    private let queue = CalculatorThread(name: "qnotch.calculator.sheet")
    private var sessions: [UUID: CalculatorSheet] = [:]
    private var recent: [UUID] = []
    private var cancellation: CalculatorCancellation?
    private var revision = 0
    /// Diagnostic runs and tests evaluate on the calling thread, so a snapshot has results at once
    /// (a request can still ask for the background).
    let synchronous: Bool
    /// Requests that are still running.
    private(set) var pending = 0

    init(synchronous: Bool) { self.synchronous = synchronous }

    func evaluate(sheet id: UUID, source: String, environment: CalculatorEnvironment, format: CalculatorFormat,
                  functions: CalculatorFunctions?, rates: CalculatorRates? = nil, uuids: CalculatorUuidContext? = nil, inBackground: Bool = false,
                  done: @escaping (Outcome) -> Void) {
        cancellation?.cancel()
        let token = CalculatorCancellation()
        cancellation = token
        revision += 1
        let current = revision
        let session = self.session(id)
        func run() -> Outcome? {
            do { return .done(try session.evaluate(source, environment: environment, format: format, functions: functions, rates: rates, uuids: uuids, cancel: token)) }
            catch { return token.isCancelled ? nil : .failed(error.localizedDescription) }
        }
        if synchronous, !inBackground {
            if let outcome = run() { done(outcome) }
            return
        }
        pending += 1
        queue.async { [weak self] in
            let outcome = token.isCancelled ? nil : run()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending -= 1
                guard self.revision == current, !token.isCancelled, let outcome else { return }
                done(outcome)
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        revision += 1
    }

    func forget(_ id: UUID) {
        sessions[id] = nil
        recent.removeAll { $0 == id }
    }

    /// Sessions of the four most recent sheets are kept, like their editors.
    private func session(_ id: UUID) -> CalculatorSheet {
        recent.removeAll { $0 == id }
        recent.append(id)
        while recent.count > 4 { sessions[recent.removeFirst()] = nil }
        if let session = sessions[id] { return session }
        let session = CalculatorSheet()
        sessions[id] = session
        return session
    }
}

/// Clipboard writes. Diagnostic runs copy to a private pasteboard, so the user's clipboard is never touched.
enum CalculatorClipboard {
    /// Tests set their own private pasteboard.
    static var board: NSPasteboard = Runtime.diagnostics ? NSPasteboard(name: NSPasteboard.Name("dev.qnotch.calculator.\(UUID().uuidString)")) : .general
    @discardableResult
    static func copy(_ text: String) -> Bool {
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}

/// The open Calculator: the sheet catalog and tab strip state, the sheet in front with its live results,
/// closing with a way back, preferences and the visible-only date refresh (Windows CalculatorSurface without
/// its views). Main thread only. Views observe it and push edits into it; it never touches a view.
final class CalculatorWorkspace {
    enum Change: Equatable {
        /// The strip changed: a tab closed, came back or the catalog changed.
        case tabs(TabChange)
        /// Another sheet is in front.
        case sheet
        case results
        case notice
        case status
        case preferences
        /// The sheet came on screen or left it.
        case visibility
        /// The rates button, its menu or the rates settings have something new to say.
        case rates
        /// The sheet in front got new text in place (a restored version): the editor takes it as one undo step.
        case replaced
        /// A dice line was rolled and its result is on screen: the toss can play.
        case rolled(CalculatorDiceRoll)
        /// The sync folder, its status or the saved functions changed (Settings and Search follow).
        case documents
    }
    enum TabChange: Equatable { case refreshed, closed(UUID, keepingPlace: Bool), restored(UUID), created(UUID), renamed(UUID) }
    struct Notice: Equatable {
        let text: String
        /// The closed sheet's way back.
        let undo: Bool
        var tip: String?
    }

    let documents: CalculatorDocuments
    let tabs: CalculatorTabState
    let evaluator: CalculatorEvaluator
    /// The exchange-rate cache, downloads and the automatic download.
    let currencies: CalculatorCurrencies
    private(set) var activeID: UUID
    /// The text of the sheet in front, saved or not.
    var source: String
    var dirty = false
    /// The latest results and the source they belong to.
    private(set) var lines: [CalculatorLineResult] = []
    private(set) var evaluatedSource = ""
    private(set) var evaluation: CalculatorEvaluation?
    private(set) var status = ""
    private(set) var notice: Notice?
    private(set) var composing = false
    private(set) var visible = false
    private(set) var format = CalculatorFormat()
    /// Results delivered so far (tests and smoke checks wait for a count).
    private(set) var deliveries = 0
    private var replacedLastSheet: (closed: UUID, fresh: UUID)?
    private var evaluationDeferred = false
    private var evaluatedAt = Date()
    private var evaluatedZone = TimeZone.current.identifier
    private var saveTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?
    private var noticeTask: DispatchWorkItem?
    private var dateTask: DispatchWorkItem?
    private var clockObservers: [NSObjectProtocol] = []
    private var observers: [UUID: (Change) -> Void] = [:]
    private(set) var closedDown = false
    /// A restored version's identities and receipts before and after, until the editor's undo step takes them.
    var pendingRestore: (before: CalculatorGeneratedCheckpoint, receipts: CalculatorFunctions?, after: CalculatorFunctions?)?
    /// The UUIDs and rolls of the sheet in front, and of recent sheets whose editors keep their undo (four, like the editors).
    var generated: CalculatorGeneratedValues
    var generatedCache: [UUID: CalculatorGeneratedValues] = [:]
    var generatedOrder: [UUID] = []
    /// Receipts an undone restore brought back; the next save writes them with the text (Windows restoredReceipts).
    var restoredReceipts: CalculatorFunctions?
    /// Saved since the last version was kept (Windows historyPending), and whether keeping one failed.
    var historyPending = false
    var historyFailed = false
    /// The sheet in front could not be read: it shows read-only until another sheet is chosen.
    private(set) var unavailable = false
    /// Before-edit identities of a change that touches lines holding UUIDs or rolls (see `willEdit`).
    var editCheckpoint: CalculatorGeneratedCheckpoint?
    /// A roll waiting for its evaluation, then shown (Windows rollShowing).
    var rollShowing: CalculatorDiceRoll?
    /// The folder sync session; nil while sync is off (Windows syncSession).
    var syncSession: CalculatorSyncSession?
    var applyingSync = false
    var syncMessage: (text: String, sticky: Bool)?
    var importing = false
    /// Saved functions or sync changed: the module tells Search.
    var documentsChanged: (() -> Void)?
    /// The clock; tests move it.
    var now: () -> Date = Date.init
    /// Typing evaluates off the main thread even in a synchronous workspace (diagnostic runs check that path).
    var typingInBackground = false

    static let saveDelay: TimeInterval = 0.5
    static let noticeSeconds: TimeInterval = 2.5

    /// `ratesDirectory` is where the rate cache lives (`<data root>/calculator`); without one, or `offlineRates`, rates are
    /// never read, written or downloaded.
    init(documents: CalculatorDocuments, tabs: CalculatorTabState, synchronous: Bool, ratesDirectory: URL? = nil, offlineRates: Bool = true) {
        self.documents = documents
        self.tabs = tabs
        evaluator = CalculatorEvaluator(synchronous: synchronous)
        currencies = CalculatorCurrencies(directory: ratesDirectory, offline: offlineRates)
        activeID = documents.activeSheetID
        let opened = (documents as? StoredCalculatorDocuments)?.openedActive ?? (try? documents.open(documents.activeSheetID))
        source = opened?.source ?? ""
        generated = opened?.generated ?? CalculatorGeneratedValues(source: "")
        format = Self.format(documents.preferences)
        if opened == nil {
            unavailable = true
            status = CalculatorText.sheetUnavailable
        } else if opened?.recovered == true || (documents as? StoredCalculatorDocuments)?.opened.recovered == true {
            status = CalculatorText.recoveredBackup
        }
        remember(generated, for: activeID)
        refreshTabs()
        currencies.changed = { [weak self] in self?.notify(.rates) }
        currencies.ratesChanged = { [weak self] in self?.ratesChanged() }
        currencies.conditions = { [weak self] in
            guard let self else { return CalculatorCurrencies.Conditions() }
            return CalculatorCurrencies.Conditions(enabled: self.documents.preferences.autoCurrencyRates, visible: self.visible && !self.closedDown,
                                                   composing: self.composing)
        }
        evaluate()
        startSync()
    }

    deinit {
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Observers

    private final class Token {
        let remove: () -> Void
        init(_ remove: @escaping () -> Void) { self.remove = remove }
        deinit { remove() }
    }

    /// The handler is called after every change while the returned token is alive.
    func observe(_ handler: @escaping (Change) -> Void) -> AnyObject {
        let id = UUID()
        observers[id] = handler
        return Token { [weak self] in self?.observers[id] = nil }
    }

    func notify(_ change: Change) {
        for handler in Array(observers.values) { handler(change) }
    }

    var preferences: CalculatorPreferences { documents.preferences }
    /// What the sheet shows: the saved preferences, or a Settings choice being looked at (Windows ApplyDisplay preview).
    var displayed: CalculatorPreferences { displayPreview ?? documents.preferences }
    private(set) var displayPreview: CalculatorPreferences?
    var activeName: String { documents.sheets.first { $0.id == activeID }?.name ?? "" }

    // MARK: Editing and evaluation

    /// The editor's text changed. Composing (an input method's marked text) defers evaluation and saving.
    func edit(_ text: String, composing: Bool = false, change: (range: NSRange, length: Int)? = nil, undo: UndoManager? = nil) {
        guard !closedDown, !unavailable else { return }
        followIdentities(text, change: change, undo: undo)
        source = text
        dirty = true
        self.composing = composing
        currencies.editing()
        if composing {
            evaluationDeferred = true
            saveTask?.cancel()
            stopDateSchedule()
            return
        }
        evaluationDeferred = false
        scheduleSave()
        evaluate(typing: true)
    }

    func evaluate(typing: Bool = false, supplied: Bool = false) {
        guard !closedDown else { return }
        let id = activeID, text = source
        let evaluatedAt = now(), zone = TimeZone.current
        let rates = currencies.rates
        let functions = documents.functions
        // The first `uuid` turns generated values on: the sheet is saved with them (Windows ReadUuidContext).
        let uuids = generated.source == text ? generated.context(for: text, functions: functions) : (context: nil, enabled: false)
        if uuids.enabled { dirty = true; if !composing { scheduleSave() } }
        evaluator.evaluate(sheet: id, source: text, environment: environment(at: evaluatedAt, zone: zone), format: format,
                           functions: functions, rates: rates, uuids: uuids.context, inBackground: typing && typingInBackground) { [weak self] outcome in
            guard let self, self.activeID == id else { return }
            if case .done(let evaluation) = outcome, evaluation.needsGeneratedValues, self.source == text {
                // New `uuid` lines get their values, then the sheet evaluates again with them (Windows Evaluate).
                if !supplied, (try? self.generated.supply(evaluation)) != nil {
                    self.dirty = true
                    if !self.composing { self.scheduleSave() }
                    self.evaluate(supplied: true)
                    return
                }
            }
            switch outcome {
            case .done(let evaluation):
                // The first sheet that converts money reads the rate cache, then evaluates again with it (Windows
                // EnsureCurrencyCache): its lines never show "no rates" for a moment.
                if evaluation.usesCurrencyRates, rates == nil, !self.currencies.isReady {
                    self.currencies.ensureLoaded { [weak self] in self?.evaluate() }
                    return
                }
                self.lines = evaluation.lines
                self.evaluation = evaluation
                if self.status == CalculatorText.finishTextInput { self.setStatus("") }
            case .failed(let message):
                self.lines = []
                self.evaluation = nil
                self.setStatus(message)
            }
            self.evaluatedSource = text
            self.evaluatedAt = evaluatedAt
            self.evaluatedZone = zone.identifier
            self.deliveries += 1
            self.refreshDateSchedule()
            if case .done(let evaluation) = outcome {
                self.currencies.adopt(uses: evaluation.usesCurrencyRates, requests: evaluation.currencyRequests)
            } else {
                self.currencies.adopt(uses: false, requests: [])
            }
            self.notify(.results)
            self.showRoll()
        }
    }

    private func environment(at date: Date, zone: TimeZone) -> CalculatorEnvironment {
        let preferences = documents.preferences
        return CalculatorEnvironment(now: date, timeZone: zone, region: Locale.current.region?.identifier,
                                     displayCurrency: preferences.defaultCurrency, workdayRegion: preferences.workdayRegion)
    }

    static func format(_ preferences: CalculatorPreferences) -> CalculatorFormat {
        CalculatorFormat(styleId: preferences.numberStyle ?? CalculatorPreferences.defaultNumberStyle, decimalPlaces: preferences.decimalPlaces)
    }

    /// The result to show for `line` of the current text, mapping the latest results across an edit that is
    /// still being evaluated: lines before and after the edited block keep their results; edited lines show none.
    /// `currentLines` is `sourceLines(source)`.
    func result(forLine index: Int, of currentLines: [Substring]) -> CalculatorLineResult? {
        guard !lines.isEmpty else { return nil }
        if evaluatedSource == source { return index < lines.count ? lines[index] : nil }
        if carried?.evaluated != evaluatedSource || carried?.current != source {
            carried = (evaluatedSource, source, Self.evaluatedLines(old: Self.sourceLines(evaluatedSource), current: currentLines))
        }
        guard let map = carried?.map, index < map.count, let mapped = map[index], mapped < lines.count else { return nil }
        return lines[mapped]
    }
    private var carried: (evaluated: String, current: String, map: [Int?])?

    /// Lines split as the engine's SourceLineMap splits them: at CRLF, CR or LF. Swift's `"\n"` Character never matches a CRLF.
    static func sourceLines(_ text: String) -> [Substring] {
        let scalars = text.unicodeScalars
        var lines: [Substring] = []
        var start = scalars.startIndex, i = start
        while i < scalars.endIndex {
            let scalar = scalars[i]
            guard scalar == "\r" || scalar == "\n" else { i = scalars.index(after: i); continue }
            lines.append(Substring(scalars[start..<i]))
            var next = scalars.index(after: i)
            if scalar == "\r", next < scalars.endIndex, scalars[next] == "\n" { next = scalars.index(after: next) }
            start = next; i = next
        }
        lines.append(Substring(scalars[start..<scalars.endIndex]))
        return lines
    }

    /// For each line of the current text, the line of the evaluated text it was before an edit: lines before and after the
    /// changed block keep their place (shifted by the lines added or removed); changed lines have none. The common start and
    /// end are each taken as far as they go; text cannot tell which of two equal lines was typed (a block pasted above its
    /// copy matches both ways), so where they overlap nothing is carried (Windows CarriedResults.Map).
    static func evaluatedLines(old: [Substring], current: [Substring]) -> [Int?] {
        var prefix = 0
        while prefix < old.count, prefix < current.count, old[prefix] == current[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count, suffix < current.count, old[old.count - 1 - suffix] == current[current.count - 1 - suffix] { suffix += 1 }
        var claims = [Int](repeating: 0, count: old.count)
        var mapped = [Int?](repeating: nil, count: current.count)
        for i in current.indices {
            let fromStart: Int? = i < prefix ? i : nil
            let fromEnd = current.count - 1 - i
            let fromFinish: Int? = fromEnd < suffix ? old.count - 1 - fromEnd : nil
            if let a = fromStart, let b = fromFinish, a != b { claims[a] += 1; claims[b] += 1; continue } // Two places: ambiguous.
            if let line = fromStart ?? fromFinish { mapped[i] = line; claims[line] += 1 }
        }
        return mapped.map { line in line.flatMap { claims[$0] == 1 ? $0 : nil } }
    }

    static func evaluatedLine(for index: Int, old: [Substring], current: [Substring]) -> Int? {
        let map = evaluatedLines(old: old, current: current)
        return index < map.count ? map[index] : nil
    }

    /// Input method composition ended without a text change.
    func compositionEnded() {
        guard composing else { return }
        composing = false
        if evaluationDeferred { evaluationDeferred = false; scheduleSave(); evaluate() }
    }

    // MARK: Saving

    func scheduleSave() {
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.save() }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: task)
    }

    /// Writes the sheet in front. False keeps it open: an unsaved sheet is never closed or left.
    @discardableResult
    func save() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        if composing { setStatus(CalculatorText.finishTextInput); return false }
        guard dirty, !unavailable else { return true }
        captureHistory(force: false) // Keeps what this save is about to replace.
        do {
            let refresh = try documents.save(activeID, source: source, generated: generated.source == source ? generated : nil, receipts: restoredReceipts)
            restoredReceipts = nil
            historyPending = true
            dirty = false
            if [CalculatorText.saveFailed, CalculatorText.recoveredBackup].contains(status) || syncMessage?.sticky == true {
                syncMessage = nil
                setStatus(historyState)
            }
            requestSync()
            if refresh {
                documentsChanged?()
                notify(.documents)
                evaluate()
            }
            return true
        } catch {
            setStatus(CalculatorText.saveFailed)
            return false
        }
    }

    /// The panel closed: pending text goes out. Waiting closes keep their own deadline.
    func flush() {
        guard !closedDown, !composing else { return }
        save()
        captureHistory(force: false)
        documents.flush()
    }

    /// QNotch quits or the feature is turned off: saves, turns waiting closes into deletes and stops every timer.
    func shutdown() {
        guard !closedDown else { return }
        composing = false
        save()
        captureHistory(force: true)
        commitClosedSheets(everything: true)
        documents.flush()
        stopSync()
        documents.close()
        closedDown = true
        evaluator.cancel()
        currencies.shutdown()
        for task in [saveTask, closeTask, noticeTask] { task?.cancel() }
        stopDateSchedule()
        observers.removeAll()
    }

    func setStatus(_ text: String) {
        guard status != text else { return }
        status = text
        notify(.status)
    }

    /// The clipboard took a result, or did not.
    func copy(_ line: CalculatorLineResult) -> Bool {
        guard CalculatorResultText.copies(line) else { return false }
        if CalculatorClipboard.copy(line.copy) { return true }
        setStatus(CalculatorText.clipboardUnavailable)
        return false
    }

    // MARK: Sheets

    private func catalog() -> [CalculatorTab] { documents.sheets.map { CalculatorTab(id: $0.id, name: $0.name) } }

    func refreshTabs() {
        tabs.update(catalog(), active: activeID)
        if !applyingSync { requestSync() } // Catalog edits publish too; nothing while sync is off.
    }

    @discardableResult
    func attempt(_ action: () throws -> Void, failure: String = CalculatorText.sheetUnavailable) -> Bool {
        do { try action(); return true } catch {
            setStatus(failure)
            return false
        }
    }

    /// Puts a sheet in front. Its generated values come from the recent sheet's own (whose editor keeps their undo) when the text
    /// still matches, otherwise from the file.
    func activate(_ id: UUID, opened: CalculatorOpenedSheet) {
        evaluator.cancel()
        saveTask?.cancel()
        activeID = id
        let text = opened.source
        source = text
        if let kept = generatedCache[id], kept.source == text { generated = kept } else { generated = opened.generated }
        remember(generated, for: id)
        unavailable = false
        restoredReceipts = nil
        historyPending = false
        editCheckpoint = nil
        rollShowing = nil
        dirty = false
        composing = false
        evaluationDeferred = false
        lines = []
        evaluation = nil
        evaluatedSource = ""
        stopDateSchedule()
        refreshTabs()
        if opened.recovered { setStatus(CalculatorText.recoveredBackup) }
        else if [CalculatorText.sheetUnavailable, CalculatorText.finishTextInput, CalculatorText.recoveredBackup].contains(status) { setStatus(historyState) }
        notify(.sheet)
        evaluate()
    }

    @discardableResult
    func switchTo(_ id: UUID) -> Bool {
        if id == activeID { return true }
        guard !tabs.isClosed(id), save() else { refreshTabs(); notify(.tabs(.refreshed)); return false }
        captureHistory(force: true)
        var opened: CalculatorOpenedSheet?
        let switched = attempt {
            opened = try documents.open(id) // Validate the sheet before committing the selection.
            try documents.select(id)
        }
        guard switched, let opened else { refreshTabs(); notify(.tabs(.refreshed)); return false }
        activate(id, opened: opened)
        notify(.tabs(.refreshed))
        return true
    }

    /// ⌃⇥ and ⌃⇧⇥.
    func cycle(_ direction: Int) {
        let visible = tabs.visible
        guard visible.count > 1, let index = visible.firstIndex(where: { $0.id == activeID }) else { return }
        switchTo(visible[(index + direction + visible.count) % visible.count].id)
    }

    @discardableResult
    func newSheet() -> Bool {
        guard tabs.canCreate else {
            showNotice(tabs.closed.isEmpty ? CalculatorText.sheetLimit(CalculatorTabList.maxSheets) : CalculatorText.sheetLimitPending(CalculatorTabList.maxSheets))
            return false
        }
        guard save() else { return false }
        captureHistory(force: true)
        var created: UUID?, opened: CalculatorOpenedSheet?
        guard attempt({
            created = try documents.create(name: tabs.uniqueName(CalculatorText.newSheetName), source: "")
            opened = try documents.open(created!)
        }), let created, let opened else { return false }
        activate(created, opened: opened)
        notify(.tabs(.created(created)))
        return true
    }

    /// Closes a tab, undoably. A tab other than the one in front closes without touching the sheet in front.
    @discardableResult
    func close(_ id: UUID) -> Bool {
        switch tabs.canClose(id) {
        case .lastSheet: return closeLastSheet(id)
        case .unknown: return false
        case .allowed: break
        }
        if id == activeID {
            if composing { setStatus(CalculatorText.finishTextInput); return false }
            guard save() else { return false }
            captureHistory(force: true)
            guard closeActive(id) else { return false }
            notify(.tabs(.closed(id, keepingPlace: false)))
        } else {
            guard tabs.close(id, now: now()) != nil else { return false }
            notify(.tabs(.closed(id, keepingPlace: true)))
        }
        armCloseTimer()
        showClosedNotice()
        return true
    }

    /// Moves to the nearest sheet that can load, then hides this one.
    private func closeActive(_ id: UUID) -> Bool {
        for neighbor in tabs.neighbors(of: id) {
            guard let opened = try? documents.open(neighbor) else { continue }
            guard tabs.close(id, now: now(), next: neighbor, wasActive: false) != nil else { return false }
            if attempt({ try documents.select(neighbor) }) {
                activate(neighbor, opened: opened)
                return true
            }
            tabs.undo(now: now())
            return false
        }
        setStatus(CalculatorText.sheetUnavailable)
        return false
    }

    /// Closing the only sheet opens an empty one in its place, as closing a browser's last tab does. Undo
    /// brings the closed sheet back in front and drops the empty one if nothing was typed into it.
    private func closeLastSheet(_ id: UUID) -> Bool {
        guard id == activeID else { return false }
        guard tabs.canCreate else { showNotice(CalculatorText.sheetLimitPending(CalculatorTabList.maxSheets)); return false }
        if composing { setStatus(CalculatorText.finishTextInput); return false }
        guard save() else { return false }
        captureHistory(force: true)
        var fresh: UUID?, opened: CalculatorOpenedSheet?
        guard attempt({
            fresh = try documents.create(name: tabs.uniqueName(CalculatorText.newSheetName), source: "")
            opened = try documents.open(fresh!)
        }), let fresh, let opened else { return false }
        activate(fresh, opened: opened)
        guard tabs.close(id, now: now(), next: nil, wasActive: true) != nil else { return false }
        replacedLastSheet = (id, fresh)
        notify(.tabs(.closed(id, keepingPlace: false)))
        armCloseTimer()
        showClosedNotice()
        return true
    }

    /// Brings back the most recently closed sheet; if it was in front when closed it comes back in front.
    @discardableResult
    func undoClose() -> Bool {
        guard let sheet = tabs.undo(now: now()) else { return false }
        armCloseTimer()
        if tabs.closed.isEmpty { hideNotice() } else { showClosedNotice() }
        // The empty sheet that stood in for the last one goes again, unless the user started using it.
        var unused: UUID?
        if let replaced = replacedLastSheet, replaced.closed == sheet.id {
            if replaced.fresh == activeID, source.isEmpty { unused = replaced.fresh }
            replacedLastSheet = nil
        }
        if sheet.wasActive, switchToRestored(sheet.id), let unused { dropUnusedSheet(unused) }
        tabs.setActive(activeID)
        notify(.tabs(.restored(sheet.id)))
        return true
    }

    /// Like `switchTo`, for a sheet the tab list already made active again.
    private func switchToRestored(_ id: UUID) -> Bool {
        if id == activeID { return true }
        guard save() else { return false }
        captureHistory(force: true)
        var opened: CalculatorOpenedSheet?
        guard attempt({ opened = try documents.open(id); try documents.select(id) }), let opened else { return false }
        activate(id, opened: opened)
        return true
    }

    private func dropUnusedSheet(_ id: UUID) {
        guard attempt({ try documents.delete([id]) }) else { return }
        evaluator.forget(id)
        forgetGenerated(id)
        refreshTabs()
    }

    private func armCloseTimer() {
        closeTask?.cancel()
        closeTask = nil
        guard let due = tabs.dueAt else { return }
        let task = DispatchWorkItem { [weak self] in self?.commitClosedSheets(everything: false) }
        closeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, due.timeIntervalSince(now())), execute: task)
    }

    /// Turns waiting closes into deletes: all of them when quitting, otherwise those whose window ended.
    func commitClosedSheets(everything: Bool) {
        let due = everything ? tabs.takeAll() : tabs.takeExpired(now: now())
        guard !due.isEmpty else {
            if !everything { armCloseTimer() }
            return
        }
        for sheet in due {
            if replacedLastSheet?.closed == sheet.id { replacedLastSheet = nil }
            evaluator.forget(sheet.id)
            forgetGenerated(sheet.id)
        }
        // One catalog change for the group. If it fails the sheets stay and show again below; nothing is lost.
        attempt { try documents.delete(due.map(\.id)) }
        if closedDown || everything { return }
        hideNotice()
        refreshTabs()
        notify(.tabs(.refreshed))
    }

    func canRename(_ id: UUID) -> Bool { documents.sheets.contains { $0.id == id } && !tabs.isClosed(id) }

    /// Nil when renamed (or unchanged), otherwise the problem to show under the field.
    func rename(_ id: UUID, to name: String) -> String? {
        guard canRename(id) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == documents.sheets.first(where: { $0.id == id })?.name { return nil }
        guard (try? InMemoryCalculatorDocuments.validName(trimmed)) != nil else { return CalculatorText.invalidSheetName }
        if id == activeID, !save() { return CalculatorText.saveFailed }
        if !CalculatorDocumentStore.isValidName(trimmed) { return CalculatorText.invalidSheetName }
        do { try documents.rename(id, to: trimmed) } catch { return CalculatorText.sheetUnavailable }
        refreshTabs()
        notify(.tabs(.renamed(id)))
        return nil
    }

    // MARK: Notices

    private func showClosedNotice() {
        guard let last = tabs.lastClosed else { return }
        noticeTask?.cancel()
        let others = tabs.closed.count - 1
        notice = Notice(text: others == 0 ? CalculatorText.closedSheet(last.name) : CalculatorText.closedSheets(last.name, others), undo: true, tip: last.name)
        notify(.notice)
    }

    /// A short note. While a close can still be undone, its notice comes back when the note ends.
    func showNotice(_ text: String) {
        notice = Notice(text: text, undo: false)
        notify(.notice)
        noticeTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.tabs.closed.isEmpty { self.hideNotice() } else { self.showClosedNotice() }
        }
        noticeTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeSeconds, execute: task)
    }

    private func hideNotice() {
        noticeTask?.cancel()
        guard notice != nil else { return }
        notice = nil
        notify(.notice)
    }

    // MARK: Preferences

    /// Shows a text size or result format while its Settings choice is highlighted, without saving it; nil ends the preview.
    func preview(_ change: ((inout CalculatorPreferences) -> Void)?) {
        guard !closedDown else { return }
        let next: CalculatorPreferences? = change.map { change in
            var preferences = documents.preferences
            change(&preferences)
            return preferences
        }
        guard next != displayPreview else { return }
        displayPreview = next
        applyDisplayed()
    }

    private func applyDisplayed() {
        let shown = Self.format(displayed)
        let reformat = shown != format
        format = shown
        notify(.preferences)
        if reformat { if composing { evaluationDeferred = true } else { evaluate() } }
    }

    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) {
        displayPreview = nil
        let before = documents.preferences
        do { try documents.updatePreferences(change) } catch {
            setStatus(CalculatorText.settingsUnavailable)
            applyDisplayed()
            return
        }
        let after = documents.preferences
        if after.language != before.language { CalculatorText.language = CalculatorInterfaceText.resolve(after.language) }
        if after.autoCurrencyRates != before.autoCurrencyRates { currencies.preferencesChanged(automatic: after.autoCurrencyRates) }
        // Only what changes answers evaluates again: not the text size or the automatic download, nor a format a preview
        // already shows.
        let evaluates = Self.format(after) != format || after.defaultCurrency != before.defaultCurrency || after.workdayRegion != before.workdayRegion
        format = Self.format(after)
        notify(.preferences)
        guard evaluates else { return }
        if composing { evaluationDeferred = true } else { evaluate() }
    }

    /// Downloaded rates replaced the cached ones: the sheet in front evaluates with them, and Search forgets its answers.
    private func ratesChanged() {
        rates?()
        guard !closedDown else { return }
        if composing { evaluationDeferred = true } else { evaluate() }
    }

    /// Called after the rates change (the module tells Search).
    var rates: (() -> Void)?

    // MARK: Visibility and the date refresh

    /// Date and second refresh run only while the sheet is on screen (Windows DateRefresh).
    func setVisible(_ value: Bool) {
        guard visible != value, !closedDown else { return }
        visible = value
        if value { dateClockChanged() } else { stopDateSchedule() }
        currencies.visibilityChanged(value)
        notify(.visibility)
    }

    /// Wake, clock and time zone changes.
    func dateClockChanged() {
        // A day later the cached rates may be stale and the automatic download due.
        currencies.refreshSchedule()
        if currencies.uses { notify(.rates) }
        stopDateSchedule()
        guard visible, let evaluation, evaluation.usesCurrentDate || evaluation.usesCurrentInstant || evaluation.usesLocalTimeZone else { return }
        if composing { evaluationDeferred = true; return }
        let current = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let zoneChanged = evaluatedZone != TimeZone.current.identifier
        let dayChanged = !calendar.isDate(evaluatedAt, inSameDayAs: current) || zoneChanged
        let secondChanged = floor(evaluatedAt.timeIntervalSince1970) != floor(current.timeIntervalSince1970)
        if evaluation.usesCurrentDate && dayChanged || evaluation.usesCurrentInstant && secondChanged || evaluation.usesLocalTimeZone && zoneChanged { evaluate() }
        else { refreshDateSchedule() }
    }

    /// One deadline: the next second for a running clock, otherwise the next local midnight. Clock and time zone
    /// notifications are observed only meanwhile.
    private func refreshDateSchedule() {
        stopDateSchedule()
        // A local-zone line needs no deadline, only the time zone notification.
        guard visible, !composing, !closedDown, let evaluation, evaluation.usesCurrentDate || evaluation.usesCurrentInstant || evaluation.usesLocalTimeZone else { return }
        if evaluation.requiresSecondRefresh || evaluation.usesCurrentDate {
            let delay = evaluation.requiresSecondRefresh ? Self.secondDelay(now()) : Self.midnightDelay(now(), zone: .current)
            let task = DispatchWorkItem { [weak self] in self?.dateClockChanged() }
            dateTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            clockObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                NSTimeZone.resetSystemTimeZone()
                self?.dateClockChanged()
            })
        }
    }

    private func stopDateSchedule() {
        dateTask?.cancel()
        dateTask = nil
        for observer in clockObservers { NotificationCenter.default.removeObserver(observer) }
        clockObservers.removeAll()
    }

    var hasDateSchedule: Bool { dateTask != nil || !clockObservers.isEmpty }

    static func secondDelay(_ now: Date) -> TimeInterval {
        let fraction = now.timeIntervalSince1970 - floor(now.timeIntervalSince1970)
        return max(0.001, 1 - fraction)
    }

    /// Time to the next local date boundary, at least one second (Windows DateRefreshSchedule).
    static func midnightDelay(_ now: Date, zone: TimeZone) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let next = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else { return 3600 }
        return max(1, next.timeIntervalSince(now))
    }
}
