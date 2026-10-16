import AppKit
import QNotchMacCore
import QuickLookThumbnailing
import Quartz

/// Drop files on the notch to keep them within reach (Windows FileTrayModule). The tray keeps
/// references, never copies: files are saved as bookmarks, so they survive renames and moves,
/// and nothing ever modifies or deletes them. Export always copies. Share uses the system
/// picker, which includes AirDrop. Nothing runs while the panel is closed.
final class FileTrayModule: NSObject, NotchModule {
    struct Item: Equatable {
        var url: URL
        var bookmark: Data?
        var missing = false
        var name: String { FileManager.default.displayName(atPath: url.path) }
    }

    private var context: ModuleContext!
    private(set) var items: [Item] = []
    private(set) var status: String?
    private var statusTask: DispatchWorkItem?
    private let io = DispatchQueue(label: "qnotch.filetray", qos: .utility)
    private var thumbnails: [URL: NSImage] = [:]
    private var requested: Set<URL> = []
    private var panelOpen = false
    private var quickLookHold: AnyObject?
    private var quickLookURL: URL?
    private let views = NSHashTable<AnyObject>.weakObjects()
    var dropActive = false { didSet { refresh() } }

    var contextShell: ModuleShell? { context.shell }
    private var fileURL: URL { context.settings.directory.appendingPathComponent("filetray.json") }

    func initialize(_ context: ModuleContext) {
        self.context = context
        load()
        context.registries.cards.register(ViewContribution(id: "filetray", title: "File tray", order: 80, symbol: "tray.full") { [unowned self] in
            self.track(FileTrayCardView(module: self))
        })
        context.registries.tabs.register(ViewContribution(id: "files", title: "Files", order: 40, symbol: "tray.full") { [unowned self] in
            self.track(FileTrayTabView(module: self))
        })
        context.registries.searchSources.register(SearchSource(id: "filetray", order: 20) { [weak self] query in
            guard let self else { return [] }
            return self.items.filter { $0.name.localizedCaseInsensitiveContains(query) }.map { item in
                SearchHit(title: item.name, detail: "File tray · opens it", symbol: "doc") { [weak self] in
                    self?.open(item.url)
                    self?.context.shell?.closePanel()
                }
            }
        })
        context.shell?.acceptFileDrops(entered: { [weak self] in
            self?.dropActive = true
            self?.context.shell?.selectTab("files")
        }, dropped: { [weak self] urls in
            self?.dropActive = false
            self?.add(urls)
        })
    }

    private func track<V: NSView & FileTrayDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        if panel == panelOpen { return }
        panelOpen = panel
        if panel {
            checkMissing()
            refresh()
        } else {
            // Thumbnails are cheap to regenerate (Quick Look caches them); don't hold them while idle.
            thumbnails.removeAll()
            requested.removeAll()
            dropActive = false
        }
    }
    func systemDidWake() {}
    func stop() { statusTask?.cancel() }

    // MARK: List

    func add(_ urls: [URL]) {
        let fresh = urls.map(\.standardizedFileURL)
        let paths = FileTrayList.adding(fresh.map(\.path), to: items.map(\.url.path))
        let known = Dictionary(items.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        items = paths.map { path in
            if let item = known[path], !fresh.contains(where: { $0.path == path }) { return item }
            let url = URL(fileURLWithPath: path)
            return Item(url: url, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        save()
        show(urls.count == 1 ? "Added \(FileManager.default.displayName(atPath: urls[0].path))" : "Added \(urls.count) files")
        refresh()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.url == item.url }
        save()
        refresh()
    }

    func clear() {
        items.removeAll()
        save()
        show("Tray cleared. Your files were not touched.")
        refresh()
    }

    private func checkMissing() {
        let snapshot = items
        io.async { [weak self] in
            let missing = snapshot.map { !FileManager.default.fileExists(atPath: $0.url.path) }
            DispatchQueue.main.async {
                guard let self, self.items.map(\.url) == snapshot.map(\.url) else { return }
                var changed = false
                for index in self.items.indices where self.items[index].missing != missing[index] {
                    self.items[index].missing = missing[index]
                    changed = true
                }
                if changed { self.refresh() }
            }
        }
    }

    // MARK: Actions

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        show("Path copied")
    }

    /// The system share picker: AirDrop, Messages, Mail and the user's share extensions.
    func share(_ urls: [URL], from view: NSView) {
        guard !urls.isEmpty else { return }
        let hold = context.shell?.holdOpen()
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        pickerHold = hold
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    private var pickerHold: AnyObject?

    /// Copies into a folder the user picks; names never overwrite ("name (2).ext").
    func export(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let hold = context.shell?.holdOpen()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = urls.count == 1 ? "Choose where to copy this file." : "Choose where to copy these \(urls.count) files."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            _ = hold
            guard response == .OK, let folder = panel.url else { return }
            self?.io.async {
                var copied = 0
                for url in urls {
                    let name = FileTrayList.uniqueName(url.lastPathComponent) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
                    if (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))) != nil { copied += 1 }
                }
                DispatchQueue.main.async {
                    self?.show(copied == urls.count ? "Copied \(copied == 1 ? "1 file" : "\(copied) files") to \(folder.lastPathComponent)"
                                                     : "Copied \(copied) of \(urls.count). Some files could not be copied.")
                }
            }
        }
    }

    func addWithPanel() {
        let hold = context.shell?.holdOpen()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            _ = hold
            if response == .OK { self?.add(panel.urls) }
        }
    }

    func quickLook(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        quickLookURL = url
        quickLookHold = context.shell?.holdOpen()
        panel.dataSource = self
        panel.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Thumbnails

    func thumbnail(for item: Item, size: CGFloat) -> NSImage? {
        if let image = thumbnails[item.url] { return image }
        guard panelOpen, !item.missing, !requested.contains(item.url) else { return nil }
        requested.insert(item.url)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 64, height: 64), scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            DispatchQueue.main.async {
                guard let self, self.panelOpen else { return }
                self.thumbnails[item.url] = image
                self.refresh()
            }
        }
        return nil
    }

    // MARK: Status, persistence

    private func show(_ text: String) {
        status = text
        statusTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.status = nil; self?.refresh() }
        statusTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
        refresh()
    }

    /// Coalesced: a burst of thumbnails or changes reloads the views once.
    private var refreshPending = false
    private func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            for case let view as FileTrayDisplay in self.views.allObjects { view.reload() }
        }
    }

    /// Smoke snapshots only: reload the views now.
    func reloadNow() {
        for index in items.indices { items[index].missing = !FileManager.default.fileExists(atPath: items[index].url.path) }
        for case let view as FileTrayDisplay in views.allObjects { view.reload() }
    }

    private struct Saved: Codable {
        struct Entry: Codable { var path: String; var bookmark: Data? }
        var items: [Entry]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), data.count < 2_000_000,
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        var changed = false
        items = saved.items.prefix(FileTrayList.limit).map { entry in
            // A bookmark follows a renamed or moved file; the path is the fallback.
            if let bookmark = entry.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    if stale || url.path != entry.path { changed = true }
                    return Item(url: url, bookmark: stale ? try? url.bookmarkData() : bookmark)
                }
            }
            return Item(url: URL(fileURLWithPath: entry.path), bookmark: entry.bookmark)
        }
        if changed { save() }
    }

    private func save() {
        let saved = Saved(items: items.map { Saved.Entry(path: $0.url.path, bookmark: $0.bookmark) })
        let url = fileURL, directory = context.settings.directory
        io.async {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension FileTrayModule: NSSharingServicePickerDelegate {
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        pickerHold = nil
    }
}

extension FileTrayModule: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { quickLookURL as NSURL? }
    func windowWillClose(_ notification: Notification) { quickLookHold = nil; quickLookURL = nil }
}
