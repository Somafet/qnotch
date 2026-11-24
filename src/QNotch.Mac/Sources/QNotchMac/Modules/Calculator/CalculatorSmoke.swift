import AppKit

/// The Calculator in diagnostic runs: extra snapshot states (`calculator-hover`, `calculator-explanation`,
/// `calculator-closed`, `calculator-all-sheets`, `calculator-rename`, `calculator-rename-variable`, `calculator-overflow`,
/// `calculator-figures`, `calculator-rates`, `calculator-history`, `calculator-dice`, `calculator-import-report`,
/// `settings-calculator-sync`) and the smoke checks `calculator-typing`, `calculator-copy`, `calculator-sheets`,
/// `calculator-last-sheet`, `calculator-rename-variable`, `calculator-line-copy`, `calculator-figure`, `calculator-search`,
/// `calculator-hidden-idle`, `calculator-persistence`, `calculator-history` and `calculator-import`. Copies go to a private
/// pasteboard; sheets live in throwaway folders and never in the user's data.
enum CalculatorSmoke {
    typealias Failure = NativeSmokeTest.Failure

    private static func page(_ shell: ShellController) -> CalculatorTabView? {
        func walk(_ view: NSView) -> CalculatorTabView? {
            if let page = view as? CalculatorTabView { return page }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return shell.panel.contentView.flatMap(walk)
    }

    // MARK: Snapshot states

    static func render(_ run: SnapshotRun) {
        let shell = run.shell
        guard shell.module(CalculatorModule.self) != nil,
              run.wants(["calculator-hover", "calculator-explanation", "calculator-closed", "calculator-all-sheets", "calculator-rename",
                         "calculator-rename-variable", "calculator-overflow", "calculator-figures", "calculator-rates",
                         "calculator-history", "calculator-dice", "calculator-import-report", "settings-calculator-sync"]) else { return }
        shell.open(keyboard: false)
        shell.selectTab(CalculatorModule.id)
        guard let page = page(shell) else { return run.fail("calculator-hover", "the Calculator page did not load") }
        page.layoutSubtreeIfNeeded()
        page.layoutResults()
        // Line 7 (250 km in miles) is rounded: its card shows the exact value.
        if let pill = page.pillsByLine[6] ?? page.pillsByLine.values.first {
            page.showCardForDiagnostics(pill)
            run.notch("calculator-hover")
            page.pillExplain(pill)
            run.notch("calculator-explanation")
            page.closeOverlay(returnFocus: false)
        }
        let workspace = page.workspace
        if let rent = workspace.tabs.visible.first(where: { $0.name == "Rent split" }) {
            workspace.close(rent.id)
            run.notch("calculator-closed")
            workspace.undoClose()
        }
        page.stripAll(page.strip.all.isHidden ? page.more : page.strip.all)
        run.notch("calculator-all-sheets")
        page.closeOverlay(returnFocus: false)
        page.renameSheet(workspace.activeID)
        run.notch("calculator-rename")
        page.closeOverlay(returnFocus: false)
        // F2 with the caret in "nights" (line 2 of the demo).
        let nights = (page.editor.string as NSString).range(of: "nights")
        if nights.location != NSNotFound {
            page.editor.setSelectedRange(NSRange(location: nights.location + 2, length: 0))
            page.editorRename()
            run.notch("calculator-rename-variable")
            page.closeOverlay(returnFocus: false)
        }
        // More sheets than fit: chevrons, the all-sheets button and the tab in front kept in view. A page of its
        // own, so the demo sheets stay as they are.
        if run.options.includes("calculator-overflow") {
            let many = InMemoryCalculatorDocuments(sheets: (1...14).map { (name: "Sheet \($0)", source: $0 == 9 ? "9 * 9" : "") }, active: 8)
            let overflow = CalculatorTabView(workspace: CalculatorWorkspace(documents: many, tabs: CalculatorStorage.makeTabState(), synchronous: true), shell: nil)
            overflow.frame = page.bounds
            overflow.appearance = Palette.dark
            overflow.layoutSubtreeIfNeeded()
            overflow.layoutResults()
            run.write("calculator-overflow", overflow, background: Palette.surface)
        }
        // A plot, a bar chart, table columns and a pie on a taller page of their own.
        if run.options.includes("calculator-figures") {
            let figures = detachedPage(source: figureSource, size: NSSize(width: page.bounds.width, height: 720))
            run.write("calculator-figures", figures, background: Palette.surface)
        }
        // The rates menu of a sheet that converts money, offline: no cache, so the rates are unavailable.
        if run.options.includes("calculator-rates") {
            let rates = detachedPage(source: "# Trip money\nhotel = 380 EUR\nhotel in USD\n120 GBP in EUR on 2025-01-06", size: page.bounds.size)
            rates.showRatesMenu()
            run.write("calculator-rates", rates, background: Palette.surface)
        }
        renderDocuments(run, page: page)
        shell.selectTab("home")
        shell.close(restoreFocus: false)
    }

    static let figureSource = "# Monthly costs\nrent = 1450\nfood = 420\ntravel = 310\nbar chart\nplot sin(x) from -6 to 6\nitem\tcost\tshare\nrent\t1450\t66%\nfood\t420\t19%\ntravel\t310\t14%\npie chart of [1450, 420, 310]"

    /// A page with one sheet of its own, so the demo sheets stay as they are.
    private static func detachedPage(source: String, size: NSSize) -> CalculatorTabView {
        let documents = InMemoryCalculatorDocuments(sheets: [(name: "Sheet", source: source)])
        let page = CalculatorTabView(workspace: CalculatorWorkspace(documents: documents, tabs: CalculatorStorage.makeTabState(), synchronous: true), shell: nil)
        page.frame = NSRect(origin: .zero, size: size)
        page.appearance = Palette.dark
        page.layoutSubtreeIfNeeded()
        page.layoutResults()
        return page
    }

    /// History, a dice roll, an import report and the sync settings, on the demo's throwaway store.
    private static func renderDocuments(_ run: SnapshotRun, page: CalculatorTabView) {
        let workspace = page.workspace
        guard let documents = workspace.documents as? StoredCalculatorDocuments else { return }
        // Two saves ten minutes apart keep two versions of the Budget sheet.
        // Earlier states already saved the sheet once; the clock moves past the five-minute interval.
        var clock = Date().addingTimeInterval(600)
        documents.now = { clock }
        let original = workspace.source
        workspace.edit(original + "\ntip = 10% of 240")
        workspace.save()
        clock += 600
        workspace.edit(original + "\ntip = 12% of 240")
        workspace.save()
        page.editor.replaceAll(with: workspace.source)
        page.layoutResults()
        page.showHistory()
        run.notch("calculator-history")
        page.closeOverlay(returnFocus: false)

        // A rolled line, its dice at rest beside it, on the short Rent split sheet.
        if let rent = workspace.tabs.visible.first(where: { $0.name == "Rent split" }) { workspace.switchTo(rent.id) }
        page.layoutSubtreeIfNeeded()
        page.editor.replaceAll(with: workspace.source + "\n\nattack = 2d6 + 3")
        workspace.edit(page.editor.string)
        page.layoutResults()
        workspace.roll(line: page.editor.lineStarts.count - 1, again: false)
        page.layoutResults()
        run.notch("calculator-dice")
        page.dismissDice()

        // An import with a file that cannot be read.
        let files = documents.directory.appendingPathComponent("import-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let groceries = files.appendingPathComponent("Groceries.txt"), broken = files.appendingPathComponent("Budget 2025.slvr")
        try? "milk = 2.49\nbread = 3.20\nmilk + bread".write(to: groceries, atomically: true, encoding: .utf8)
        try? "{\"sheet\": ".write(to: broken, atomically: true, encoding: .utf8)
        page.importFiles([groceries, broken])
        page.needsLayout = true
        page.layoutSubtreeIfNeeded()
        page.layoutResults()
        run.notch("calculator-import-report")
        page.closeOverlay(returnFocus: false)

        // Sync settings with a folder chosen.
        if run.options.includes("settings-calculator-sync") {
            // Beside the throwaway data folder: a sync folder may not be inside the calculator's own folder.
            let folder = documents.directory.deletingLastPathComponent().appendingPathComponent("calculator-demo-sync-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            workspace.setSyncFolder(folder)
            let settings = CalculatorSettingsView.page(workspace)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: SettingsController.contentWidth + 48, height: 10))
            embed(settings, in: host, inset: NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), fill: true)
            host.frame.size.height = host.fittingSize.height
            host.appearance = Palette.dark
            host.layoutSubtreeIfNeeded()
            run.write("settings-calculator-sync", host, background: .windowBackgroundColor)
            workspace.setSyncFolder(nil)
        }
    }

    // MARK: Smoke checks

    /// Waits on the main run loop until `condition` holds or `seconds` pass, then calls `body(held)`.
    private static func wait(_ seconds: TimeInterval, until condition: @escaping () -> Bool, _ body: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func poll() {
            if condition() { return body(true) }
            if Date() >= deadline { return body(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
        }
        poll()
    }

    private static func key(_ shell: ShellController, _ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: shell.panel.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        // As NSApplication does: key equivalents go to the window's views first.
        if flags.contains(.command), shell.panel.performKeyEquivalent(with: event) { return }
        shell.panel.sendEvent(event)
    }

    static func exercise(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        guard let module = shell.module(CalculatorModule.self) else { return done(Failure("calculator-typing", "Calculator is not running")) }
        shell.close(restoreFocus: false)
        shell.selectTab(CalculatorModule.id)
        shell.open(keyboard: true)
        guard let page = page(shell), let workspace = module.workspace else { return done(Failure("calculator-typing", "the Calculator page did not load")) }
        let sheetsBefore = workspace.tabs.visible.count
        // ⌘T: a new sheet in front with the caret in it.
        key(shell, 17, "t", .command)
        guard workspace.tabs.visible.count == sheetsBefore + 1, workspace.source.isEmpty, shell.panel.firstResponder === page.editor else {
            return done(Failure("calculator-sheets", "⌘T did not open a new sheet with the caret in it"))
        }
        // Typing updates the results, evaluated off the main thread.
        let delivered = workspace.deliveries
        page.editor.type("price = 12\nprice * 3")
        guard workspace.deliveries == delivered, workspace.evaluator.pending > 0 else {
            return done(Failure("calculator-typing", "typing waited for its result instead of evaluating off the main thread"))
        }
        wait(3, until: { workspace.deliveries > delivered && page.pillsByLine[1]?.text == "36" }) { ok in
            guard ok else { return done(Failure("calculator-typing", "typing did not show 36 beside line 2 (pills: \(page.pillsByLine.mapValues(\.text)))")) }
            run.pass("calculator-typing")
            guard let pill = page.pillsByLine[1], pill.accessibilityPerformPress(),
                  CalculatorClipboard.board.string(forType: .string) == "36", pill.showsCopied else {
                return done(Failure("calculator-copy", "pressing the result did not copy 36 and confirm it"))
            }
            run.pass("calculator-copy")
            checkSheets(run, page: page, workspace: workspace) { error in
                if let error { return done(error) }
                checkEditing(run, page: page, workspace: workspace) { error in
                if let error { return done(error) }
                checkSearch(run, module: module) { error in
                    if let error { return done(error) }
                    shell.selectTab(CalculatorModule.id)
                    shell.open(keyboard: false)
                    guard workspace.visible else { return done(Failure("calculator-hidden-idle", "the shown Calculator is not marked visible")) }
                    shell.selectTab("home")
                    guard !workspace.visible, !workspace.hasDateSchedule, workspace.evaluator.pending == 0 else {
                        return done(Failure("calculator-hidden-idle", "a hidden Calculator kept a date timer or an evaluation"))
                    }
                    shell.close(restoreFocus: false)
                    run.pass("calculator-hidden-idle")
                    checkDocuments(run, done: done)
                }
                }
            }
        }
    }

    /// F2 at a variable renames it everywhere in one undo step; ⌘C, ⌘V and ⌘X with no selection copy, duplicate and
    /// cut the caret's line; a plot draws under its line as an image VoiceOver can read.
    private static func checkEditing(_ run: SnapshotRun, page: CalculatorTabView, workspace: CalculatorWorkspace, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        let original = "price = 12\nprice * 3"
        guard let editor = page.editor, editor.string == original else { return done(Failure("calculator-rename-variable", "the typed sheet is not in front")) }
        shell.panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        key(shell, 120, String(UnicodeScalar(UInt16(NSF2FunctionKey))!))
        guard let card = page.overlayContent as? RenameCard, card.identifier?.rawValue == "calculator-rename-variable-card",
              card.field.stringValue == "price" else {
            return done(Failure("calculator-rename-variable", "F2 at a variable did not open its rename card"))
        }
        card.field.stringValue = "cost"
        key(shell, 36, "\r")
        guard page.overlayContent == nil, editor.string == "cost = 12\ncost * 3", shell.panel.firstResponder === editor else {
            return done(Failure("calculator-rename-variable", "Return did not rename every occurrence and return to the sheet (\(editor.string.debugDescription))"))
        }
        wait(3, until: { workspace.evaluatedSource == editor.string && page.pillsByLine[1]?.text == "36" }) { ok in
            guard ok else { return done(Failure("calculator-rename-variable", "the renamed sheet did not evaluate to 36")) }
            editor.undoManager?.undo()
            guard editor.string == original else { return done(Failure("calculator-rename-variable", "one Undo did not bring every occurrence back")) }
            run.pass("calculator-rename-variable")

            editor.setSelectedRange(NSRange(location: 13, length: 0))
            key(shell, 8, "c", .command)
            guard CalculatorClipboard.board.string(forType: .string) == "price * 3\n",
                  CalculatorClipboard.board.types?.contains(SheetTextView.wholeLineType) == true else {
                return done(Failure("calculator-line-copy", "⌘C with no selection did not copy the caret's line"))
            }
            key(shell, 9, "v", .command)
            guard editor.string == original + "\nprice * 3" else { return done(Failure("calculator-line-copy", "⌘V did not duplicate the line (\(editor.string.debugDescription))")) }
            key(shell, 7, "x", .command)
            guard editor.string == original else { return done(Failure("calculator-line-copy", "⌘X with no selection did not cut the caret's line")) }
            run.pass("calculator-line-copy")

            editor.type("price = 12\nplot x^2 from 0 to 2")
            wait(3, until: { page.figures[1] != nil }) { ok in
                guard ok, let figure = page.figures[1], figure.superview === editor, figure.accessibilityRole() == .image,
                      figure.accessibilityLabel()?.hasPrefix("Plot of x^2") == true, let row = editor.rowRect(ofLine: 1),
                      abs(figure.frame.minY - row.maxY) < 1 else {
                    return done(Failure("calculator-figure", "a plot did not draw under its line as a named image"))
                }
                run.pass("calculator-figure")
                done(nil)
            }
        }
    }

    /// ⌘W closes with Undo; a middle-click closes another tab in place; Undo brings each back.
    private static func checkSheets(_ run: SnapshotRun, page: CalculatorTabView, workspace: CalculatorWorkspace, done: @escaping (Error?) -> Void) {
        let shell = run.shell
        let typed = workspace.activeID
        key(shell, 13, "w", .command)
        guard workspace.tabs.isClosed(typed), workspace.activeID != typed, workspace.notice?.undo == true, !page.notice.isHidden else {
            return done(Failure("calculator-sheets", "⌘W did not close the sheet with an Undo notice"))
        }
        page.notice.undo.performClick(nil)
        guard !workspace.tabs.isClosed(typed), workspace.activeID == typed, workspace.source == "price = 12\nprice * 3" else {
            return done(Failure("calculator-sheets", "Undo did not bring the closed sheet back in front with its text"))
        }
        guard let other = workspace.tabs.visible.first(where: { $0.id != typed }), let tab = page.strip.view(for: other.id) else {
            return done(Failure("calculator-sheets", "no other tab to middle-click"))
        }
        tab.middleClick(releasedInside: false)
        guard !workspace.tabs.isClosed(other.id) else { return done(Failure("calculator-sheets", "a middle-click released away from the tab closed it")) }
        tab.middleClick(releasedInside: true)
        guard workspace.tabs.isClosed(other.id), workspace.activeID == typed else {
            return done(Failure("calculator-sheets", "a middle-click did not close the other tab while keeping the sheet in front"))
        }
        workspace.undoClose()
        guard !workspace.tabs.isClosed(other.id), workspace.activeID == typed else { return done(Failure("calculator-sheets", "Undo did not restore the middle-clicked tab behind")) }
        run.pass("calculator-sheets")

        // Closing every sheet but one, then the last: an empty sheet takes its place; Undo brings it back.
        let all = workspace.tabs.visible.map(\.id)
        for id in all where id != typed { workspace.close(id) }
        guard workspace.tabs.visible.map(\.id) == [typed] else { return done(Failure("calculator-last-sheet", "closing all but one left \(workspace.tabs.visible.count) tabs")) }
        workspace.close(typed)
        guard workspace.tabs.visible.count == 1, workspace.activeID != typed, workspace.source.isEmpty, workspace.tabs.isClosed(typed) else {
            return done(Failure("calculator-last-sheet", "closing the last sheet did not replace it with an empty one"))
        }
        let fresh = workspace.activeID
        workspace.undoClose()
        guard workspace.activeID == typed, !workspace.documents.sheets.contains(where: { $0.id == fresh }) else {
            return done(Failure("calculator-last-sheet", "Undo did not bring the last sheet back and drop the unused empty one"))
        }
        while workspace.undoClose() {}
        guard workspace.tabs.visible.count == all.count, workspace.activeID == typed else {
            return done(Failure("calculator-last-sheet", "Undo did not restore every closed sheet"))
        }
        run.pass("calculator-last-sheet")
        done(nil)
    }

    /// A calculation in Search: no hit on the keystroke, then the answer off the main thread; Return copies it.
    private static func checkSearch(_ run: SnapshotRun, module: CalculatorModule, done: @escaping (Error?) -> Void) {
        let search = module.search
        search.forget()
        guard search.find("plain words").isEmpty, search.find("12*3+1").isEmpty, search.isCalculating else {
            return done(Failure("calculator-search", "the first keystroke answered synchronously or never started a calculation"))
        }
        wait(3, until: { !search.isCalculating }) { _ in
            let hits = search.find("12*3+1")
            guard let hit = hits.first, hit.title == "37" else { return done(Failure("calculator-search", "Search did not answer 37 (\(hits.map(\.title)))")) }
            hit.run()
            guard CalculatorClipboard.board.string(forType: .string) == "37", !run.shell.state.expanded else {
                return done(Failure("calculator-search", "running the answer did not copy it and close the panel"))
            }
            run.pass("calculator-search")
            done(nil)
        }
    }

    /// The real store in its own throwaway folder: what was typed is there after a quit and reopen, a version comes back, and an
    /// imported file becomes a sheet. Nothing of the user's is read or written.
    private static func checkDocuments(_ run: SnapshotRun, done: @escaping (Error?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qnotch-calculator-smoke-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = folder.appendingPathComponent("calculator", isDirectory: true)
        func open() throws -> CalculatorWorkspace {
            CalculatorWorkspace(documents: try StoredCalculatorDocuments(directory: data), tabs: CalculatorStorage.makeTabState(), synchronous: true)
        }
        do {
            var workspace = try open()
            workspace.edit("rent = 1450\nrent / 2")
            workspace.newSheet()
            workspace.edit("uuid")
            let value = workspace.lines.first?.answer ?? ""
            workspace.shutdown()
            workspace = try open()
            guard workspace.documents.sheets.count == 2, workspace.source == "uuid", workspace.lines.first?.answer == value, value.count == 36 else {
                workspace.shutdown()
                return done(Failure("calculator-persistence", "the sheets, the text or the UUID did not come back after a reopen"))
            }
            run.pass("calculator-persistence")

            let documents = workspace.documents as? StoredCalculatorDocuments
            var clock = Date()
            documents?.now = { clock }
            workspace.edit("first = 1")
            workspace.save()
            clock += 600
            workspace.edit("second = 2")
            workspace.save()
            guard let version = workspace.loadHistory()?.versions.first(where: { $0.source == "first = 1" }),
                  workspace.restoreVersion(version, of: workspace.activeID), workspace.source == "first = 1",
                  (try? workspace.documents.open(workspace.activeID).source) == "first = 1" else {
                workspace.shutdown()
                return done(Failure("calculator-history", "an earlier version was not kept or not restored"))
            }
            run.pass("calculator-history")

            let file = folder.appendingPathComponent("Groceries.txt")
            try "milk = 2\nbread = 3\nmilk + bread".write(to: file, atomically: true, encoding: .utf8)
            var created = 0
            workspace.importFiles([file]) { count, _ in created = count }
            let imported = created == 1 && workspace.activeName == "Groceries" && workspace.lines.last?.answer == "5"
            workspace.shutdown()
            guard imported else { return done(Failure("calculator-import", "the text file did not become a sheet with its results")) }
            run.pass("calculator-import")
            done(nil)
        } catch {
            done(Failure("calculator-persistence", "the store did not open: \(error.localizedDescription)"))
        }
    }
}
