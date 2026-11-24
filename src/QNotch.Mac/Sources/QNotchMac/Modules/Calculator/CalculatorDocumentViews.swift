import AppKit
import UniformTypeIdentifiers
import CalculatorEngine

/// The Calculator tab's saved-documents controls (Windows CalculatorSurface.Share, .History, .Import and .Dice): the Share menu with
/// copies, exports, print and the share link; version history; imports; the dice toss.
extension CalculatorTabView {
    func configureShare() {
        shareButton.identifier = NSUserInterfaceItemIdentifier("calculator-share")
        shareButton.refusesFirstResponder = true
        shareButton.toolTip = CalculatorText.share
        shareButton.handler = { [weak self] in self?.showShareMenu() }
    }

    /// ⌘O import, ⌘P print, ⌘⇧L copy link, ⌘? help (Windows Ctrl+O, Ctrl+P, Ctrl+Shift+L and F1).
    func documentKeyEquivalent(modifiers: NSEvent.ModifierFlags, key: String?) -> Bool {
        guard !workspace.composing else { return false }
        if modifiers == .command, key == "o", workspace.keepsDocuments { closeOverlay(returnFocus: false); chooseImport(); return true }
        if modifiers == .command, key == "p" { closeOverlay(returnFocus: false); printSheet(); return true }
        if modifiers == [.command, .shift], key == "l", workspace.keepsDocuments { workspace.copyShareLink(dark: true); return true }
        if modifiers == [.command, .shift], key == "/" || key == "?", workspace.keepsDocuments { workspace.openHelp(); return true }
        return false
    }

    // MARK: Share

    /// The Share menu, under its button. Entries act on the sheet as it shows when the menu opened.
    func showShareMenu() {
        let export: CalculatorExport
        do { export = try workspace.currentExport() } catch {
            workspace.setStatus((error as? CalculatorDocumentError)?.message ?? CalculatorText.exportFailed)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true, _ action: @escaping () -> Void) {
            let entry = item(title, key: key, modifiers: modifiers, action)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        add(CalculatorText.copyResults, enabled: export.hasResults) { [weak self] in self?.copyResults(export) }
        add(CalculatorText.copyTotal, enabled: export.totalText != nil) { [weak self] in self?.copyTotal(export) }
        add(CalculatorText.copyTable, enabled: export.hasContent) { [weak self] in self?.copyTable(export) }
        add(CalculatorText.copyImage) { [weak self] in self?.copyImage(export, transparent: false) }
        add(CalculatorText.copyTransparentImage) { [weak self] in self?.copyImage(export, transparent: true) }
        if workspace.keepsDocuments {
            add(CalculatorText.copyShareLink, key: "l", modifiers: [.command, .shift]) { [weak self] in self?.workspace.copyShareLink(dark: true) }
        }
        menu.addItem(.separator())
        add(CalculatorText.exportMenu) { [weak self] in self?.exportSheet(export) }
        add(CalculatorText.printMenu, key: "p") { [weak self] in self?.printSheet(export) }
        popUp(menu, at: NSPoint(x: shareButton.frame.maxX - menu.size.width, y: shareButton.frame.maxY + 4))
    }

    private func finish(_ written: Bool, _ done: String) {
        workspace.setStatus(written ? done : CalculatorText.clipboardUnavailable)
    }

    func copyResults(_ export: CalculatorExport) {
        guard let text = try? export.resultsText() else { return workspace.setStatus(CalculatorText.exportFailed) }
        finish(CalculatorClipboard.copy(text), CalculatorText.resultsCopied)
    }

    func copyTotal(_ export: CalculatorExport) {
        guard let total = export.totalText else { return }
        finish(CalculatorClipboard.copy(total), CalculatorText.totalCopied)
    }

    /// Tab-separated text for spreadsheets and the same table as HTML for documents.
    func copyTable(_ export: CalculatorExport) {
        guard let text = try? export.tableText(), let html = try? export.tableHTML() else { return workspace.setStatus(CalculatorText.exportFailed) }
        let board = CalculatorClipboard.board
        board.clearContents()
        let written = board.setString(text, forType: .string) && board.setString(html, forType: .html)
        finish(written, CalculatorText.tableCopied)
    }

    private var imageWidth: CGFloat { min(1194, max(480, card.bounds.width + 56)) }

    func copyImage(_ export: CalculatorExport, transparent: Bool) {
        do {
            let image = try CalculatorExportRenderer.png(export, width: imageWidth, theme: .sheet(fontSize: CGFloat(workspace.displayed.resolvedFontSize)), transparent: transparent)
            let board = CalculatorClipboard.board
            board.clearContents()
            // Applications that read PNG keep the transparency; TIFF readers get the same pixels.
            let written = board.setData(image.data, forType: .png) && (image.image.tiffRepresentation.map { board.setData($0, forType: .tiff) } ?? false)
            finish(written, CalculatorText.linesOmitted(CalculatorText.imageCopied, image.omitted))
        } catch {
            workspace.setStatus(CalculatorText.exportFailed)
        }
    }

    // MARK: Export and print

    private static let exportChoices: [(title: String, format: CalculatorExportFormat)] = [
        ("Text", .plainText), ("Markdown", .markdown), ("CSV", .csv), ("PDF", .pdf), ("PNG", .png), ("PNG, transparent", .transparentPng)
    ]

    /// The save panel with a format choice (Windows ExportSheet). Diagnostic runs never show a panel.
    func exportSheet(_ export: CalculatorExport) {
        guard !Runtime.diagnostics, let window else { return }
        let panel = NSSavePanel()
        panel.title = CalculatorText.exportSheet
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let format = NSPopUpButton(frame: .zero, pullsDown: false)
        format.addItems(withTitles: Self.exportChoices.map(\.title))
        format.identifier = NSUserInterfaceItemIdentifier("calculator-export-format")
        let stem = (CalculatorExportFormat.plainText.suggestedName(export.title) as NSString).deletingPathExtension
        func apply() {
            let choice = Self.exportChoices[max(0, format.indexOfSelectedItem)].format
            panel.allowedContentTypes = [UTType(filenameExtension: String(choice.fileExtension.dropFirst())) ?? .data]
            panel.nameFieldStringValue = stem + choice.fileExtension
        }
        format.onAction { apply() }
        let accessory = row([label("Format:", size: 12, color: .labelColor), format], spacing: 8)
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        apply()
        let hold = shell?.holdOpen()
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(hold) {}
            guard let self, response == .OK, let url = panel.url else { return }
            self.write(export, as: Self.exportChoices[max(0, format.indexOfSelectedItem)].format, to: url)
        }
    }

    func write(_ export: CalculatorExport, as format: CalculatorExportFormat, to url: URL) {
        var done = CalculatorText.exported
        do {
            let data: Data
            switch format {
            case .plainText, .markdown, .csv: data = try export.text(format)
            case .pdf: data = try CalculatorExportRenderer.pdf(export)
            case .png, .transparentPng:
                let image = try CalculatorExportRenderer.png(export, width: imageWidth, theme: .sheet(fontSize: CGFloat(workspace.displayed.resolvedFontSize)),
                                                             transparent: format == .transparentPng)
                data = image.data
                done = CalculatorText.linesOmitted(done, image.omitted)
            }
            let target = url.pathExtension.isEmpty ? url.appendingPathExtension(String(format.fileExtension.dropFirst())) : url
            try CalculatorExport.write(data, to: target)
            workspace.setStatus(done)
        } catch {
            workspace.setStatus(CalculatorText.exportFailed)
        }
    }

    /// The system print panel for the sheet's pages (Windows PrintSheet).
    func printSheet(_ given: CalculatorExport? = nil) {
        guard !Runtime.diagnostics, let window else { return }
        do {
            let export = try given ?? workspace.currentExport()
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            let view = try CalculatorExportRenderer.PrintView(export, paper: info.paperSize)
            let operation = NSPrintOperation(view: view, printInfo: info)
            operation.jobTitle = export.title
            let hold = shell?.holdOpen()
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            withExtendedLifetime(hold) {}
            workspace.setStatus(CalculatorText.sentToPrinter)
        } catch {
            workspace.setStatus(CalculatorText.printFailed)
        }
    }

    // MARK: Import

    /// The open panel for .numi, .slvr and .txt files (Windows ImportSheets).
    func chooseImport() {
        guard workspace.keepsDocuments, !Runtime.diagnostics, let window else { return }
        let panel = NSOpenPanel()
        panel.title = CalculatorText.importTitle
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = CalculatorImport.extensions.compactMap { UTType(filenameExtension: $0) }
        let hold = shell?.holdOpen()
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(hold) {}
            guard response == .OK else { return }
            self?.importFiles(panel.urls)
        }
    }

    /// Imports and shows the report of notes and rejections, if any (Windows ImportAndReport).
    func importFiles(_ urls: [URL]) {
        workspace.importFiles(urls.filter(CalculatorImport.isSupported)) { [weak self] _, report in
            guard let self, !report.isEmpty else { return }
            self.showReport(CalculatorText.importTitle, report)
        }
    }

    func showReport(_ title: String, _ text: String) {
        let card = ExplanationCard(text: text, title: title, id: "calculator-import-report")
        card.close.handler = { [weak self] in self?.closeOverlay(returnFocus: true) }
        card.escape = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(card, width: 420, anchor: nil, focus: card.text)
    }

    // MARK: Version history

    /// Saved versions beside a preview. Restoring takes a second, explicit press (Windows ShowHistory).
    func showHistory() {
        guard let history = workspace.loadHistory() else { return }
        let sheet = workspace.activeID
        let card = HistoryCard(history: history)
        card.restore = { [weak self] version in
            guard let self else { return }
            self.closeOverlay(returnFocus: true)
            // Sync may have put another sheet in front: this history is not its history.
            guard self.workspace.activeID == sheet else { return }
            self.workspace.restoreVersion(version, of: sheet)
        }
        card.close = { [weak self] in self?.closeOverlay(returnFocus: true) }
        present(card, width: history.versions.isEmpty ? 320 : 620, anchor: more, focus: card.focusView)
    }

    /// A restored version replaces the editor's text as one undo step.
    func replaceEditorText() {
        guard let editor else { return }
        replacingText = true
        editor.replaceAllUndoably(with: workspace.source)
        replacingText = false
        workspace.replacedText(undo: editor.undoManager)
        layoutResults()
    }

    // MARK: Dice

    /// The rolled dice tumble in beside their line, then the result shows (Windows ShowRoll and DiceToss). Reduce Motion
    /// shows them settled with a short fade. They stay until the next key, click, scroll or edit.
    func playRoll(_ roll: CalculatorDiceRoll) {
        NSAccessibility.post(element: editor as Any, notification: .announcementRequested,
                             userInfo: [.announcement: CalculatorText.rolled(workspace.lines.indices.contains(roll.line) ? workspace.lines[roll.line].answer : ""),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        dismissDice()
        guard Motion.fades, let editor, let row = editor.rowRect(ofLine: roll.line) else { return }
        let visible = scroll.contentView.bounds
        guard row.maxY > visible.minY, row.minY < visible.maxY else { return }
        let size = (CGFloat(workspace.displayed.resolvedFontSize) * 1.9).rounded()
        let pointInCard = NSPoint(x: scroll.frame.minX + min(editor.endOfLine(roll.line) + 14, card.bounds.width - gutterWidth - 40),
                                  y: scroll.frame.minY + row.midY - visible.minY)
        let layer = DiceTossView(roll: roll, size: size, accent: Palette.accent, ink: Palette.card)
        layer.frame = card.bounds
        card.addSubview(layer)
        diceLayer = layer
        let pill = pillsByLine[roll.line]
        pill?.alphaValue = 0
        layer.play(at: pointInCard) { [weak pill] in
            guard let pill else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                pill.animator().alphaValue = 1
            }
        }
        layer.dismissed = { [weak self, weak pill] in
            pill?.alphaValue = 1
            if self?.diceLayer === layer { self?.diceLayer = nil }
        }
    }

    func dismissDice() {
        diceLayer?.dismiss()
        diceLayer = nil
    }

    private var gutterWidth: CGFloat { results.frame.width }
}

extension SheetTextView {
    /// The x of a line's last character in this view.
    func endOfLine(_ index: Int) -> CGFloat {
        guard let layoutManager, lineStarts.indices.contains(index) else { return 0 }
        let text = string as NSString
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : text.length
        guard end > lineStarts[index] else { return textContainerOrigin.x }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: end - 1, length: 1), actualCharacterRange: nil)
        guard let container = textContainer else { return 0 }
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX + textContainerOrigin.x
    }
}

/// Saved versions on the left, the selected one's text on the right, Restore asking once more before it acts.
final class HistoryCard: OverlayCard, NSTableViewDataSource, NSTableViewDelegate {
    private let history: CalculatorVersionHistory
    private let table = NSTableView()
    private let preview = OverlayTextView()
    private let confirm = label("", size: 12, color: .systemOrange)
    private let restoreButton = HoverButton(CalculatorText.restore, style: .accent, label: CalculatorText.restoreVersion) {}
    private var armed = -1
    var restore: ((CalculatorSheetVersion) -> Void)?
    var close: (() -> Void)?
    private(set) var focusView: NSView?

    init(history: CalculatorVersionHistory) {
        self.history = history
        super.init(id: "calculator-history", label: CalculatorText.versionHistory)
        let closeButton = HoverButton(CalculatorText.close, style: .plain, label: CalculatorText.close) { [weak self] in self?.close?() }
        closeButton.identifier = NSUserInterfaceItemIdentifier("calculator-history-close")
        for button in [closeButton, restoreButton] { button.padding = NSSize(width: 14, height: 4) }
        let title = Self.title(CalculatorText.versionHistory)
        guard !history.versions.isEmpty else {
            let empty = label(CalculatorText.noVersions, size: 12, color: Palette.textSecondary)
            let stack = Self.column([title, empty, row([spacer(), closeButton], spacing: 8)], spacing: 10)
            embed(stack, in: self, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), fill: true)
            stack.arrangedSubviews.last?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            focusView = closeButton
            return
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("version"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier("calculator-history-list")
        table.setAccessibilityLabel(CalculatorText.versions)
        let list = NSScrollView()
        list.documentView = table
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        let text = NSScrollView()
        text.drawsBackground = false
        text.hasVerticalScroller = true
        text.autohidesScrollers = true
        text.scrollerStyle = .overlay
        preview.isEditable = false
        preview.drawsBackground = false
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = Palette.textPrimary
        preview.textContainerInset = NSSize(width: 0, height: 2)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = .width
        preview.textContainer?.widthTracksTextView = true
        preview.identifier = NSUserInterfaceItemIdentifier("calculator-history-preview")
        preview.setAccessibilityLabel(CalculatorText.versionPreview)
        preview.escape = { [weak self] in self?.close?() }
        text.documentView = preview
        restoreButton.identifier = NSUserInterfaceItemIdentifier("calculator-history-restore")
        restoreButton.handler = { [weak self] in self?.restorePressed() }
        confirm.isHidden = true
        let panes = row([list, text], spacing: 12)
        let stack = Self.column([title, panes, confirm, row([spacer(), closeButton, restoreButton], spacing: 8)], spacing: 10)
        embed(stack, in: self, inset: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), fill: true)
        NSLayoutConstraint.activate([
            list.widthAnchor.constraint(equalToConstant: 176),
            list.heightAnchor.constraint(equalToConstant: 214),
            text.heightAnchor.constraint(equalToConstant: 214),
            panes.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.arrangedSubviews.last!.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        focusView = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView { QNotchMac.column(views, spacing: spacing) }

    func numberOfRows(in tableView: NSTableView) -> Int { history.versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text = label(CalculatorWorkspace.versionLabel(history.versions[row]), size: 12, color: Palette.textPrimary)
        text.lineBreakMode = .byTruncatingTail
        return text
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        armed = -1
        confirm.isHidden = true
        let row = table.selectedRow
        restoreButton.isEnabled = row >= 0
        preview.string = row >= 0 ? history.versions[row].source : ""
        preview.scrollToBeginningOfDocument(nil)
    }

    private func restorePressed() {
        let row = table.selectedRow
        guard row >= 0 else { return }
        let version = history.versions[row]
        guard armed == row else {
            armed = row
            confirm.stringValue = CalculatorText.restorePrompt(CalculatorWorkspace.versionLabel(version))
            confirm.isHidden = false
            return
        }
        restore?(version)
    }

    override func cancelOperation(_ sender: Any?) { close?() }
}

/// Dice tumbling in beside their line, then resting until the next action (Windows DiceToss, restrained): a short, critically damped
/// spring from a little above with a few degrees of turn, staggered by die. Kept dice are filled in the accent; dropped ones are outlined.
final class DiceTossView: NSView {
    private let roll: CalculatorDiceRoll
    private let size: CGFloat
    private let accent: NSColor, ink: NSColor
    private var monitor: Any?
    var dismissed: (() -> Void)?

    init(roll: CalculatorDiceRoll, size: CGFloat, accent: NSColor, ink: NSColor) {
        self.roll = roll; self.size = size; self.accent = accent; self.ink = ink
        super.init(frame: .zero)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("calculator-dice")
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// At most twelve dice show; the result says the rest.
    func play(at origin: NSPoint, settled: @escaping () -> Void) {
        let dice = Array(roll.dice.prefix(12))
        let gap = (size * 0.22).rounded()
        let moves = Motion.moves
        for (index, die) in dice.enumerated() {
            let face = CALayer()
            face.frame = CGRect(x: origin.x + CGFloat(index) * (size + gap), y: origin.y - size / 2, width: size, height: size)
            face.cornerRadius = size * 0.22
            face.backgroundColor = die.kept ? accent.cgColor : NSColor.clear.cgColor
            face.borderColor = accent.cgColor
            face.borderWidth = die.kept ? 0 : 1.5
            let text = CATextLayer()
            text.string = String(die.face)
            text.font = NSFont.monospacedDigitSystemFont(ofSize: size * 0.46, weight: .bold)
            text.fontSize = size * 0.46
            text.alignmentMode = .center
            text.foregroundColor = die.kept ? ink.cgColor : accent.cgColor
            text.contentsScale = window?.backingScaleFactor ?? 2
            text.frame = CGRect(x: 0, y: (size - size * 0.58) / 2, width: size, height: size * 0.6)
            face.addSublayer(text)
            face.contentsScale = text.contentsScale
            layer?.addSublayer(face)
            let delay = CACurrentMediaTime() + (moves ? Double(index) * 0.03 : 0)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = moves ? 0.12 : Motion.crossfadeDuration
            fade.beginTime = delay; fade.fillMode = .backwards
            face.add(fade, forKey: "fade")
            if moves {
                let drop = Motion.spring("transform", response: 0.36, dampingRatio: 1)
                var start = CATransform3DMakeTranslation(0, -size * 0.9, 0)
                start = CATransform3DRotate(start, (index % 2 == 0 ? 1 : -1) * 0.35, 0, 0, 1)
                start = CATransform3DScale(start, 0.7, 0.7, 1)
                drop.fromValue = start
                drop.toValue = CATransform3DIdentity
                drop.beginTime = delay; drop.fillMode = .backwards
                face.add(drop, forKey: "drop")
            }
        }
        let total = moves ? 0.36 + Double(max(0, dice.count - 1)) * 0.03 : Motion.crossfadeDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + total, execute: settled)
        // Resting dice belong to this moment: the next key, click or scroll puts them away.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard superview != nil else { return }
        dismissed?()
        dismissed = nil
        if Motion.fades {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.removeFromSuperview() })
        } else {
            removeFromSuperview()
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
