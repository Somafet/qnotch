import AppKit
import CalculatorEngine

/// A notepad calculator (Windows CalculatorModule): a tab of sheets with live answers, its Settings page and
/// answers in Search. It costs nothing until first used: the engine, the editor and the sheets load the first
/// time the tab shows, its Settings page opens or Search sees a calculation. While hidden it keeps no timers,
/// apart from the one-shot undo window after a close. Analytics records nothing: the shared catalog has no
/// calculator actions.
final class CalculatorModule: NotchModule {
    static let id = "calculator"
    static let symbol = "plus.forwardslash.minus"

    private var context: ModuleContext!
    private(set) var workspace: CalculatorWorkspace?
    private var opening = false
    private var waiting: [(CalculatorWorkspace?) -> Void] = []
    let search = CalculatorSearch()
    private weak var host: CalculatorHostView?
    private var showing = false
    private var stopped = false
    var shell: ModuleShell? { context.shell }

    func initialize(_ context: ModuleContext) {
        self.context = context
        let registries = context.registries
        registries.tabs.register(ViewContribution(id: Self.id, title: CalculatorText.title, order: 25, symbol: Self.symbol) { [unowned self] in
            let host = CalculatorHostView(module: self)
            self.host = host
            if self.showing { host.load() }
            return host
        })
        registries.settingsSections.register(ViewContribution(id: Self.id, title: CalculatorText.title, order: 35, symbol: Self.symbol, tint: .systemGray) { [unowned self] in
            CalculatorSettingsView(module: self)
        })
        registries.searchSources.register(SearchSource(id: Self.id, order: 1) { [weak self] query in self?.search.find(query) ?? [] })
        // Saved functions answer in Search once the workspace is open; Search never opens it just for them.
        search.functions = { [weak self] in self?.workspace?.documents.functions?.libraryOnly }
        search.rates = { [weak self] in self?.workspace?.currencies.rates }
        search.answered = { [weak self] in self?.shell?.searchResultsChanged() }
        search.run = { [weak self] answer in
            CalculatorClipboard.copy(answer.copy)
            self?.shell?.closePanel()
        }
        // Files dragged over the notch: a tile when any of them can become a sheet. Only the names are looked at.
        registries.dropSources.register(DropSource(id: Self.id, title: CalculatorText.title, glyph: Self.symbol, order: 30) { [weak self] files in
            guard self != nil, files.contains(where: CalculatorImport.isSupported) else { return [] }
            return [DropTarget(id: "calculator.import", title: CalculatorText.importAsSheets, glyph: "square.and.arrow.down") { [weak self] files in
                self?.importDropped(files)
            }]
        })
    }

    /// Opens the Calculator tab and imports every supported file as a new sheet (Windows ImportDropped).
    func importDropped(_ files: [URL]) {
        let supported = files.filter(CalculatorImport.isSupported)
        guard !supported.isEmpty else { return }
        shell?.selectTab(Self.id)
        shell?.tryOpenPanel(tab: Self.id, linger: 4)
        withWorkspace { [weak self] workspace in
            guard let workspace else { return }
            self?.host?.load()
            if let page = self?.host?.page { page.importFiles(supported) } else { workspace.importFiles(supported) { _, _ in } }
        }
    }

    /// The open workspace, opened off the main thread on first need (synchronously in diagnostic runs).
    func withWorkspace(_ body: @escaping (CalculatorWorkspace?) -> Void) {
        if let workspace { return body(workspace) }
        guard !stopped else { return body(nil) }
        waiting.append(body)
        guard !opening else { return }
        opening = true
        let directory = context.settings.directory.appendingPathComponent("calculator", isDirectory: true)
        let demo = Runtime.diagnostics
        let finish: (Result<CalculatorDocuments, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            self.opening = false
            var opened: CalculatorWorkspace?
            if !self.stopped, case .success(let documents) = result {
                let workspace = CalculatorWorkspace(documents: documents, tabs: CalculatorStorage.makeTabState(), synchronous: demo,
                                                    ratesDirectory: directory, offlineRates: demo)
                workspace.typingInBackground = true
                workspace.rates = { [weak self] in self?.search.forget() }
                workspace.documentsChanged = { [weak self] in self?.search.forget() }
                CalculatorText.language = CalculatorInterfaceText.resolve(documents.preferences.language)
                workspace.setVisible(self.showing)
                self.workspace = workspace
                self.search.forget()
                opened = workspace
            }
            let callbacks = self.waiting
            self.waiting.removeAll()
            callbacks.forEach { $0(opened) }
        }
        if demo {
            finish(Result { try CalculatorStorage.open(directory: directory, demo: true) })
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try CalculatorStorage.open(directory: directory, demo: false) }
                DispatchQueue.main.async { finish(result) }
            }
        }
    }

    func setVisibility(panel: Bool, activeTab: String) {
        showing = panel && activeTab == Self.id
        if showing { host?.load() }
        workspace?.setVisible(showing)
        if !panel {
            // Answers can depend on today's date; pending text goes out.
            search.forget()
            workspace?.flush()
        }
    }

    func systemDidWake() {
        search.forget()
        workspace?.dateClockChanged()
    }

    func stop() {
        stopped = true
        workspace?.shutdown()
        workspace = nil
        search.forget()
    }
}
