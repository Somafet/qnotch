import AppKit
import CalculatorEngine

/// The saved-documents side of the open Calculator (Windows CalculatorSurface.Uuids, .Dice, .History, .Sync, .Import, .Share and
/// .ShareLink without their views): generated values that follow edits and undo, rolls, version history, folder sync, imports,
/// exports, share links, help and notices. Main thread only.
extension CalculatorWorkspace {
    // MARK: Generated values

    /// Recent sheets keep their own values, so an editor's undo still finds them (four, like the editors).
    func remember(_ values: CalculatorGeneratedValues, for id: UUID) {
        generatedCache[id] = values
        generatedOrder.removeAll { $0 == id }
        generatedOrder.append(id)
        while generatedOrder.count > 4 { generatedCache[generatedOrder.removeFirst()] = nil }
    }

    func forgetGenerated(_ id: UUID) {
        generatedCache[id] = nil
        generatedOrder.removeAll { $0 == id }
    }

    /// Before the editor changes `range` of the text: true when the change touches a line holding a UUID or a roll. The editor then
    /// starts a new undo step, and the identities before and after it travel with that step (Windows UuidEditorBinding).
    @discardableResult
    func willEdit(_ range: NSRange) -> Bool {
        editCheckpoint = nil
        let lines = generated.linesWithValues
        guard !lines.isEmpty, generated.source == source else { return false }
        let first = Self.line(of: range.location, in: source), last = Self.line(of: NSMaxRange(range), in: source)
        guard lines.contains(integersIn: first...last) || (first...last).contains(where: lines.contains) else { return false }
        editCheckpoint = generated.checkpoint()
        return true
    }

    static func line(of offset: Int, in text: String) -> Int {
        var line = 0, position = 0
        for unit in text.utf16 {
            if position >= offset { break }
            if unit == 0x0A { line += 1 }
            position += 1
        }
        return line
    }

    /// Moves identities with their statements across an edit. The editor's own undo and redo put back the identities registered with
    /// them; an edit that registered none is followed by comparing the texts.
    func followIdentities(_ text: String, change: (range: NSRange, length: Int)?, undo: UndoManager?) {
        defer { editCheckpoint = nil }
        if let undo, undo.isUndoing || undo.isRedoing {
            if generated.source != text { generated.apply(text) }
            return
        }
        if generated.source == text { return }
        if let change { generated.apply(text, range: change.range, replacementLength: change.length) } else { generated.apply(text) }
        if let before = editCheckpoint, let undo { registerIdentities(undo, values: generated, restoring: before, then: generated.checkpoint()) }
    }

    /// Undo puts `restoring` back and registers the way forward again.
    func registerIdentities(_ undo: UndoManager, values: CalculatorGeneratedValues, restoring: CalculatorGeneratedCheckpoint, then other: CalculatorGeneratedCheckpoint,
                            receipts: (restore: CalculatorFunctions?, other: CalculatorFunctions?)? = nil) {
        // The manager owns this handler, so it is captured weakly; a strong capture kept evicted editors' undo history alive.
        undo.registerUndo(withTarget: self) { [weak undo] workspace in
            values.restore(restoring)
            if let receipts, values === workspace.generated {
                workspace.restoredReceipts = receipts.restore
                workspace.dirty = true
                workspace.scheduleSave()
            }
            guard let undo else { return }
            workspace.registerIdentities(undo, values: values, restoring: other, then: restoring, receipts: receipts.map { ($0.other, $0.restore) })
        }
    }

    // MARK: Dice

    /// A dice line was submitted: Return on it (`again` false) or ⌘Return (`again` true). Zero-based line.
    func roll(line: Int, again: Bool) {
        guard !closedDown, !unavailable, !composing, generated.source == source else { return }
        do {
            guard let roll = try generated.roll(line: line, again: again) else { return }
            dirty = true
            scheduleSave()
            rollShowing = roll
            evaluate()
        } catch {
            setStatus((error as? CalculatorDocumentError)?.message ?? error.localizedDescription)
        }
    }

    /// After an evaluation is shown: the toss plays for a fresh roll that is still the line's roll (Windows ShowRoll).
    func showRoll() {
        guard let shown = rollShowing else { return }
        rollShowing = nil
        guard let held = generated.rolled(line: shown.line), held.faces == shown.faces, shown.line < lines.count, lines[shown.line].hasValue else { return }
        notify(.rolled(held))
    }

    // MARK: Version history

    var historyState: String { historyFailed ? CalculatorText.historyNotSaved : "" }

    /// Keeps the saved content as a version: on every save (deferred by the five-minute interval) and, forced, when the sheet is left
    /// after being saved (Windows CaptureHistory).
    func captureHistory(force: Bool) {
        guard !unavailable, !(force && !historyPending) else { return }
        do {
            if try documents.captureVersion(activeID, force: force) { historyPending = false }
            historyFailed = false
        } catch {
            historyFailed = true
            setStatus(historyState)
        }
    }

    /// True when the workspace keeps history, syncs and shares (the real store).
    var keepsDocuments: Bool { documents.store != nil }

    /// The sheet in front's versions, after saving it. Nil (with a status) when they cannot be read.
    func loadHistory() -> CalculatorVersionHistory? {
        guard keepsDocuments, !unavailable, save() else { return nil }
        var history: CalculatorVersionHistory?
        guard attempt({ history = try documents.versions(of: activeID) }, failure: CalculatorText.historyMissing), let history else { return nil }
        if history.skipped > 0 { setStatus(CalculatorText.skippedVersions(history.skipped)) }
        return history
    }

    /// Restores a version of `sheet` (still in front). The store commits first, so a failure leaves the editor as it was; the text then
    /// replaces the editor's as one undo step that also carries the identities and receipts (Windows RestoreSheetVersion).
    @discardableResult
    func restoreVersion(_ version: CalculatorSheetVersion, of sheet: UUID) -> Bool {
        guard sheet == activeID, !unavailable, save() else { return false }
        let beforeReceipts = documents.functions
        let before = generated.checkpoint()
        var restored: CalculatorOpenedSheet?
        guard attempt({ restored = try documents.restoreVersion(activeID, hash: version.hash) }, failure: CalculatorText.restoreFailed), let restored else {
            // A partial journal replay can still roll forward; the next save writes what the editor shows.
            restoredReceipts = beforeReceipts
            dirty = true
            return false
        }
        pendingRestore = (before, beforeReceipts, documents.functions)
        source = restored.source
        generated.restore(restored.generated.checkpoint())
        dirty = false
        historyPending = true
        notify(.replaced)
        setStatus("")
        evaluate()
        requestSync() // The restored text is saved like an edit, so it reaches the sync folder like one.
        return true
    }

    /// The view replaced the editor's text: the restore's identities and receipts join that undo step.
    func replacedText(undo: UndoManager?) {
        guard let pending = pendingRestore else { return }
        pendingRestore = nil
        guard let undo else { return }
        registerIdentities(undo, values: generated, restoring: pending.before, then: generated.checkpoint(), receipts: (pending.receipts, pending.after))
    }

    static func versionLabel(_ version: CalculatorSheetVersion) -> String {
        DateFormatter.localizedString(from: version.capturedAt, dateStyle: .short, timeStyle: .medium)
    }

    // MARK: Folder sync

    /// Nothing starts unless a folder was chosen (Windows StartSync).
    func startSync() {
        guard let store = documents.store else { return }
        let folder: URL?
        do { folder = try CalculatorSyncSession.configuredFolder(in: store) } catch {
            showSyncMessage(CalculatorText.syncUnavailable, sticky: false)
            return
        }
        guard folder != nil else { return }
        try? ensureSyncSession()?.start()
    }

    @discardableResult
    private func ensureSyncSession() -> CalculatorSyncSession? {
        if let syncSession { return syncSession }
        guard let store = documents.store else { return nil }
        let device = Host.current().localizedName ?? "Mac"
        let session = CalculatorSyncSession(store: store, device: device, post: { action in DispatchQueue.main.async(execute: action) },
                                            canApply: { [weak self] in self?.canApplySync() ?? false },
                                            completed: { [weak self] report in self?.applySyncReport(report) })
        syncSession = session
        return session
    }

    func requestSync() { if !applyingSync { syncSession?.request() } }

    func stopSync() {
        syncSession?.dispose()
        syncSession = nil
    }

    /// The pass reads saved files, so pending edits are written first; composing text defers it.
    private func canApplySync() -> Bool { !closedDown && !composing && save() }

    func applySyncReport(_ report: CalculatorSyncReport) {
        guard !closedDown else { return }
        if report.catalogChanged {
            applyingSync = true
            defer { applyingSync = false }
            documents.reloadCatalog()
            for id in report.changedSheets {
                forgetGenerated(id)
                evaluator.forget(id)
            }
            if !documents.sheets.contains(where: { $0.id == activeID }) {
                tabs.update(documents.sheets.map { CalculatorTab(id: $0.id, name: $0.name) }, active: documents.activeSheetID)
                let next = tabs.activeID
                if attempt({ let opened = try documents.open(next); try documents.select(next); activate(next, opened: opened) }) {}
            } else if report.changedSheets.contains(activeID) {
                let id = activeID
                if attempt({ activate(id, opened: try documents.open(id)) }) {}
            } else {
                refreshTabs()
            }
            notify(.tabs(.refreshed))
        }
        let message: String? = switch report.status {
        case .folderUnavailable: CalculatorText.syncFolderUnavailable
        case .failed: CalculatorText.syncFailed
        case .waiting: CalculatorText.syncWaiting
        default: report.conflicts > 0 ? CalculatorText.syncConflicts(report.conflicts) : nil
        }
        if let message { showSyncMessage(message, sticky: report.status == .synchronized) }
        else if let shown = syncMessage, !shown.sticky, !dirty {
            // Waiting, unavailable and failed clear once resolved; a conflict note stays until the next save.
            syncMessage = nil
            if status == shown.text { setStatus(historyState) }
        }
        notify(.documents)
    }

    private func showSyncMessage(_ text: String, sticky: Bool) {
        syncMessage = (text, sticky)
        setStatus(text)
    }

    var syncFolder: URL? { syncSession?.folder }

    /// Chooses a sync folder, or with nil stops syncing (files on both sides are kept). False with a status when it could not be set.
    @discardableResult
    func setSyncFolder(_ folder: URL?) -> Bool {
        defer { notify(.documents) }
        guard let store = documents.store, save() else { return false }
        return attempt({
            if let folder {
                if let problem = CalculatorSyncSession.problem(with: folder, in: store) { throw CalculatorDocumentsErrorMessage(problem) }
                try ensureSyncSession()?.setFolder(folder)
            } else {
                stopSync()
                try CalculatorSyncSession.clearFolder(in: store)
                if let shown = syncMessage, status == shown.text { syncMessage = nil; setStatus(historyState) }
            }
        }, failure: CalculatorText.syncUnavailable)
    }

    // MARK: Import

    /// Reads and parses off the main thread, then creates one sheet per accepted file and opens the last. A rejected file creates nothing;
    /// the files are only read. `done` gets a report of rejections and notes (empty when clean) — Windows ImportFiles.
    func importFiles(_ files: [URL], done: @escaping (_ created: Int, _ report: String) -> Void) {
        guard !importing, !files.isEmpty, !closedDown else { return done(0, "") }
        guard save() else { return done(0, CalculatorText.importStopped) }
        importing = true
        let before = status
        setStatus(CalculatorText.importing)
        let batch = Array(files.prefix(CalculatorImport.maxFiles))
        let parse = { batch.map { url -> (URL, Result<CalculatorImportedSheet, Error>) in (url, Result { try CalculatorImport.read(url) }) } }
        let finish: ([(URL, Result<CalculatorImportedSheet, Error>)]) -> Void = { [weak self] parsed in
            guard let self else { return }
            self.importing = false
            guard !self.closedDown else { return done(0, "") }
            // Typing during the parse must reach disk before another sheet replaces the editor.
            guard self.save() else { self.setStatus(before); return done(0, CalculatorText.importStopped) }
            self.captureHistory(force: true)
            var report: [String] = [], created = 0, last: UUID?, count = 0
            func add(_ line: String) { if count < 40 { report.append(line) }; count += 1 }
            for (url, result) in parsed {
                let file = url.lastPathComponent
                switch result {
                case .failure(let error):
                    add(CalculatorText.notImported(file, (error as? CalculatorDocumentError)?.message ?? error.localizedDescription))
                case .success(let sheet):
                    guard self.tabs.canCreate else { add(CalculatorText.notImported(file, CalculatorText.sheetLimit(CalculatorTabList.maxSheets))); continue }
                    // Sheets waiting for their delete still hold their names.
                    let name = CalculatorImport.uniqueName(sheet.name, existing: self.documents.sheets.map(\.name))
                    do {
                        last = try self.documents.create(name: name, source: sheet.source)
                        created += 1
                        self.tabs.update(self.documents.sheets.map { CalculatorTab(id: $0.id, name: $0.name) }, active: self.activeID)
                        if !sheet.notices.isEmpty { add(CalculatorText.importedAs(file, name)) }
                        for notice in sheet.notices { add(notice.line > 0 ? CalculatorText.importLine(notice.line, notice.message) : "  " + notice.message) }
                    } catch {
                        add(CalculatorText.notImported(file, (error as? CalculatorDocumentError)?.message ?? error.localizedDescription))
                    }
                }
            }
            if files.count > batch.count { add(CalculatorText.moreFilesNotImported(files.count - batch.count, CalculatorImport.maxFiles)) }
            if count > 40 { report.append(CalculatorText.moreNotes(count - 40)) }
            if let last, self.attempt({ let opened = try self.documents.open(last); self.activate(last, opened: opened) }) {
                self.notify(.tabs(.created(last)))
            } else {
                // The new sheets exist; the catalog's selection stays with the sheet still shown.
                let id = self.activeID
                self.attempt { try self.documents.select(id) }
                self.refreshTabs()
                self.notify(.tabs(.refreshed))
                if last == nil { self.setStatus(before) }
            }
            if created > 0 { self.setStatus(CalculatorText.imported(created)) }
            done(created, report.joined(separator: "\n"))
        }
        if evaluator.synchronous { finish(parse()) } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let parsed = parse()
                DispatchQueue.main.async { finish(parsed) }
            }
        }
    }

    // MARK: Export and share

    /// What the sheet shows now. Results belong to the text they were computed for; a sheet mid-evaluation exports its text alone.
    func currentExport() throws -> CalculatorExport {
        try CalculatorExport(title: activeName.isEmpty ? CalculatorText.firstSheetName : activeName, source: source,
                             evaluation: evaluatedSource == source ? evaluation : nil)
    }

    /// Copies a frozen browser link to the sheet (Windows CopyShareLink). Nothing is uploaded, fetched or watched.
    func copyShareLink(dark: Bool) {
        if composing { return setStatus(CalculatorText.finishTextInput) }
        guard let store = documents.store, !unavailable else { return }
        let link: String
        do {
            link = try CalculatorShareLink.create(store: store, title: activeName, source: source, evaluation: evaluatedSource == source ? evaluation : nil,
                                                  dark: dark, today: now()) { [lines] index in
                index < lines.count ? CalculatorResultText.explanation(lines[index]) : nil
            }
        } catch let error as CalculatorDocumentError {
            return setStatus(error.kind == .invalidValue ? error.message : CalculatorText.shareSettingsUnavailable)
        } catch {
            return setStatus(CalculatorText.shareSettingsUnavailable)
        }
        // A file:// link opens only on a Mac with the viewer at the same path; say so instead of implying a portable link.
        guard CalculatorClipboard.copy(link) else { return setStatus(CalculatorText.clipboardUnavailable) }
        setStatus(CalculatorShareLink.isLocal(link) ? CalculatorText.localLinkCopied : CalculatorText.linkCopied)
    }

    /// The link copied last (diagnostics).
    var lastShareLink: String? { CalculatorClipboard.board.string(forType: .string).flatMap { $0.contains("#c1.") ? $0 : nil } }

    // MARK: Help and notices

    func openHelp() { openWritten { try $0.writeHelp() } }
    func openNotices() { openWritten { try $0.writeNotices() } }

    /// Writes the bundled file into the data folder and opens it. Diagnostic runs never launch a browser.
    private func openWritten(_ write: (CalculatorDocumentStore) throws -> URL) {
        guard let store = documents.store else { return setStatus(CalculatorText.helpUnavailable) }
        do {
            let url = try write(store)
            if !Runtime.diagnostics { NSWorkspace.shared.open(url) }
        } catch {
            setStatus(CalculatorText.helpUnavailable)
        }
    }
}

/// A plain message as an error.
struct CalculatorDocumentsErrorMessage: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
