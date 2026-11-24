import AppKit
import CalculatorEngine

/// Evaluates sheets off the main thread. A newer request cancels the one before it and only the newest
/// outcome is delivered, on the main thread; a sheet's session reuses its unchanged lines.
final class CalculatorEvaluator {
    enum Outcome { case done(CalculatorEvaluation), failed(String) }

    private let queue = DispatchQueue(label: "qnotch.calculator.sheet", qos: .userInitiated)
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
                  functions: CalculatorFunctions?, inBackground: Bool = false, done: @escaping (Outcome) -> Void) {
        cancellation?.cancel()
        let token = CalculatorCancellation()
        cancellation = token
        revision += 1
        let current = revision
        let session = self.session(id)
        func run() -> Outcome? {
            do { return .done(try session.evaluate(source, environment: environment, format: format, functions: functions, cancel: token)) }
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
    private(set) var activeID: UUID
    /// The text of the sheet in front, saved or not.
    private(set) var source: String
    private(set) var dirty = false
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
    private var closedDown = false
    /// The clock; tests move it.
    var now: () -> Date = Date.init
    /// Typing evaluates off the main thread even in a synchronous workspace (diagnostic runs check that path).
    var typingInBackground = false

    static let saveDelay: TimeInterval = 0.5
    static let noticeSeconds: TimeInterval = 2.5

    init(documents: CalculatorDocuments, tabs: CalculatorTabState, synchronous: Bool) {
        self.documents = documents
        self.tabs = tabs
        evaluator = CalculatorEvaluator(synchronous: synchronous)
        activeID = documents.activeSheetID
        source = (try? documents.source(of: documents.activeSheetID)) ?? ""
        format = Self.format(documents.preferences)
        refreshTabs()
        evaluate()
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

    private func notify(_ change: Change) {
        for handler in Array(observers.values) { handler(change) }
    }

    var preferences: CalculatorPreferences { documents.preferences }
    var activeName: String { documents.sheets.first { $0.id == activeID }?.name ?? "" }

    // MARK: Editing and evaluation

    /// The editor's text changed. Composing (an input method's marked text) defers evaluation and saving.
    func edit(_ text: String, composing: Bool = false) {
        guard !closedDown else { return }
        source = text
        dirty = true
        self.composing = composing
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

    func evaluate(typing: Bool = false) {
        guard !closedDown else { return }
        let id = activeID, text = source
        let evaluatedAt = now(), zone = TimeZone.current
        evaluator.evaluate(sheet: id, source: text, environment: environment(at: evaluatedAt, zone: zone), format: format,
                           functions: documents.functions, inBackground: typing && typingInBackground) { [weak self] outcome in
            guard let self, self.activeID == id else { return }
            switch outcome {
            case .done(let evaluation):
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
            self.notify(.results)
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
    func result(forLine index: Int, of currentLines: [Substring]) -> CalculatorLineResult? {
        guard !lines.isEmpty else { return nil }
        if evaluatedSource == source { return index < lines.count ? lines[index] : nil }
        let old = evaluatedSource.split(separator: "\n", omittingEmptySubsequences: false)
        guard let mapped = Self.evaluatedLine(for: index, old: old, current: currentLines), mapped < lines.count else { return nil }
        return lines[mapped]
    }

    /// The line of the evaluated text that `index` of the current text was before an edit: lines before and
    /// after the changed block keep their place (shifted by the lines added or removed); changed lines have none.
    static func evaluatedLine(for index: Int, old: [Substring], current: [Substring]) -> Int? {
        guard index < current.count else { return nil }
        var prefix = 0
        while prefix < old.count, prefix < current.count, old[prefix] == current[prefix] { prefix += 1 }
        if index < prefix { return index }
        var suffix = 0
        while suffix < old.count - prefix, suffix < current.count - prefix, old[old.count - 1 - suffix] == current[current.count - 1 - suffix] { suffix += 1 }
        let fromEnd = current.count - 1 - index
        guard fromEnd < suffix else { return nil }
        return old.count - 1 - fromEnd
    }

    /// Input method composition ended without a text change.
    func compositionEnded() {
        guard composing else { return }
        composing = false
        if evaluationDeferred { evaluationDeferred = false; scheduleSave(); evaluate() }
    }

    // MARK: Saving

    private func scheduleSave() {
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
        guard dirty else { return true }
        do {
            try documents.save(activeID, source: source)
            dirty = false
            if status == CalculatorText.saveFailed { setStatus("") }
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
        documents.flush()
    }

    /// QNotch quits or the feature is turned off: saves, turns waiting closes into deletes and stops every timer.
    func shutdown() {
        guard !closedDown else { return }
        composing = false
        save()
        commitClosedSheets(everything: true)
        documents.flush()
        closedDown = true
        evaluator.cancel()
        for task in [saveTask, closeTask, noticeTask] { task?.cancel() }
        stopDateSchedule()
        observers.removeAll()
    }

    private func setStatus(_ text: String) {
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

    private func refreshTabs() { tabs.update(catalog(), active: activeID) }

    @discardableResult
    private func attempt(_ action: () throws -> Void) -> Bool {
        do { try action(); return true } catch {
            setStatus(CalculatorText.sheetUnavailable)
            return false
        }
    }

    private func activate(_ id: UUID, source text: String) {
        evaluator.cancel()
        saveTask?.cancel()
        activeID = id
        source = text
        dirty = false
        composing = false
        evaluationDeferred = false
        lines = []
        evaluation = nil
        evaluatedSource = ""
        stopDateSchedule()
        refreshTabs()
        if status == CalculatorText.sheetUnavailable || status == CalculatorText.finishTextInput { setStatus("") }
        notify(.sheet)
        evaluate()
    }

    @discardableResult
    func switchTo(_ id: UUID) -> Bool {
        if id == activeID { return true }
        guard !tabs.isClosed(id), save() else { refreshTabs(); notify(.tabs(.refreshed)); return false }
        var text = ""
        let switched = attempt {
            text = try documents.source(of: id)
            try documents.select(id)
        }
        guard switched else { refreshTabs(); notify(.tabs(.refreshed)); return false }
        activate(id, source: text)
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
        var created: UUID?
        guard attempt({ created = try documents.create(name: tabs.uniqueName(CalculatorText.newSheetName), source: "") }), let created else { return false }
        activate(created, source: "")
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
            guard save(), closeActive(id) else { return false }
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
            guard let text = try? documents.source(of: neighbor) else { continue }
            guard tabs.close(id, now: now(), next: neighbor, wasActive: false) != nil else { return false }
            if attempt({ try documents.select(neighbor) }) {
                activate(neighbor, source: text)
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
        var fresh: UUID?
        guard attempt({ fresh = try documents.create(name: tabs.uniqueName(CalculatorText.newSheetName), source: "") }), let fresh else { return false }
        activate(fresh, source: "")
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
        var text = ""
        guard attempt({ text = try documents.source(of: id); try documents.select(id) }) else { return false }
        activate(id, source: text)
        return true
    }

    private func dropUnusedSheet(_ id: UUID) {
        guard attempt({ try documents.delete([id]) }) else { return }
        evaluator.forget(id)
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

    func updatePreferences(_ change: (inout CalculatorPreferences) -> Void) {
        do { try documents.updatePreferences(change) } catch {
            setStatus(CalculatorText.settingsUnavailable)
            notify(.preferences)
            return
        }
        format = Self.format(documents.preferences)
        notify(.preferences)
        if composing { evaluationDeferred = true } else { evaluate() }
    }

    // MARK: Visibility and the date refresh

    /// Date and second refresh run only while the sheet is on screen (Windows DateRefresh).
    func setVisible(_ value: Bool) {
        guard visible != value, !closedDown else { return }
        visible = value
        if value { dateClockChanged() } else { stopDateSchedule() }
    }

    /// Wake, clock and time zone changes.
    func dateClockChanged() {
        stopDateSchedule()
        guard visible, let evaluation, evaluation.usesCurrentDate || evaluation.usesCurrentInstant else { return }
        if composing { evaluationDeferred = true; return }
        let current = now()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let dayChanged = !calendar.isDate(evaluatedAt, inSameDayAs: current) || evaluatedZone != TimeZone.current.identifier
        let secondChanged = floor(evaluatedAt.timeIntervalSince1970) != floor(current.timeIntervalSince1970)
        if evaluation.usesCurrentDate && dayChanged || evaluation.usesCurrentInstant && secondChanged { evaluate() } else { refreshDateSchedule() }
    }

    /// One deadline: the next second for a running clock, otherwise the next local midnight. Clock and time zone
    /// notifications are observed only meanwhile.
    private func refreshDateSchedule() {
        stopDateSchedule()
        guard visible, !composing, !closedDown, let evaluation, evaluation.usesCurrentDate || evaluation.usesCurrentInstant else { return }
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
