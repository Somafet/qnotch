import AppKit
import QNotchMacCore

/// Your launchd agents (Windows ScheduledModule, which lists Task Scheduler tasks): scripts and
/// jobs on a timer, with Pause, Resume and Delete. Read when the panel opens (one `launchctl list`
/// and one `print-disabled`, on a utility queue); no timers, no polling.
final class ScheduledModule: NotchModule {
    private var context: ModuleContext!
    private(set) var jobs: [LaunchAgentJob] = []
    private(set) var loadedOnce = false
    private var panelOpen = false
    private(set) var error = ""
    var showAppAgents = false { didSet { refreshViews() } }
    private(set) var confirming: String?
    private let io = DispatchQueue(label: "qnotch.scheduled", qos: .utility)
    private let views = NSHashTable<AnyObject>.weakObjects()
    var contextShell: ModuleShell? { context.shell }
    private static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    private static let domain = "gui/\(getuid())"

    func initialize(_ context: ModuleContext) {
        self.context = context
        context.registries.cards.register(ViewContribution(id: "scheduled", title: "Scheduled tasks", order: 90, symbol: "clock.arrow.2.circlepath") { [unowned self] in
            self.track(ScheduledCardView(module: self))
        })
        context.registries.tabs.register(ViewContribution(id: "scheduled", title: "Scheduled", order: 60, symbol: "clock.arrow.2.circlepath") { [unowned self] in
            self.track(ScheduledTabView(module: self))
        })
        context.registries.searchSources.register(SearchSource(id: "scheduled", order: 50) { [weak self] query in
            guard let self else { return [] }
            return self.visible.filter { $0.label.localizedCaseInsensitiveContains(query) || $0.program.localizedCaseInsensitiveContains(query) }.map { job in
                SearchHit(title: job.label, detail: "Scheduled task · \(job.schedule)", symbol: "clock.arrow.2.circlepath") { [weak self] in
                    self?.context.shell?.selectTab("scheduled")
                }
            }
        })
        reload()
    }

    private func track<V: NSView & ScheduledDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    /// Reads once per panel opening, not on every tab switch while it is open.
    func setVisibility(panel: Bool, activeTab: String) {
        guard panel != panelOpen else { return }
        panelOpen = panel
        if panel { reload() } else { confirming = nil }
    }
    func systemDidWake() {}
    func stop() {}

    var visible: [LaunchAgentJob] { jobs.filter { showAppAgents || !$0.fromApp } }
    var hiddenCount: Int { jobs.filter(\.fromApp).count }

    func refreshViews() { for case let view as ScheduledDisplay in views.allObjects { view.reload() } }

    // MARK: Reading

    func reload() {
        io.async { [weak self] in
            let files = ((try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "plist" }
            var jobs = files.compactMap { url -> LaunchAgentJob? in
                guard let data = try? Data(contentsOf: url),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
                return LaunchAgentJob.parse(plist, path: url.path)
            }
            let list = LaunchAgentJob.parseList(Self.launchctl(["list"]).output)
            let disabled = LaunchAgentJob.parseDisabled(Self.launchctl(["print-disabled", Self.domain]).output)
            for index in jobs.indices {
                let state = list[jobs[index].label]
                jobs[index].loaded = state != nil
                jobs[index].running = state?.pid != nil
                jobs[index].lastExit = state?.status
                jobs[index].disabled = disabled.contains(jobs[index].label)
            }
            jobs.sort { ($0.failed ? 0 : 1, $0.label.lowercased()) < ($1.failed ? 0 : 1, $1.label.lowercased()) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.jobs = jobs
                self.loadedOnce = true
                self.refreshViews()
            }
        }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Actions

    /// Pause unloads the agent and disables it, so it stays off after a restart; Resume reverses both.
    func setPaused(_ job: LaunchAgentJob, _ pause: Bool) {
        error = ""
        io.async { [weak self] in
            let service = "\(Self.domain)/\(job.label)"
            let result: (status: Int32, output: String)
            if pause {
                Self.launchctl(["disable", service])
                result = job.loaded ? Self.launchctl(["bootout", Self.domain, job.path]) : (0, "")
            } else {
                Self.launchctl(["enable", service])
                result = Self.launchctl(["bootstrap", Self.domain, job.path])
            }
            DispatchQueue.main.async {
                // Already loaded (or already gone) is not a failure.
                if result.status != 0, ![5, 36, 37].contains(result.status) {
                    self?.error = "launchctl could not \(pause ? "pause" : "resume") \(job.label): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                self?.reload()
            }
        }
    }

    func askDelete(_ job: LaunchAgentJob?) {
        confirming = job?.label
        refreshViews()
    }

    /// Unloads the agent and moves its plist to the Trash, so it can be restored from there.
    func delete(_ job: LaunchAgentJob) {
        confirming = nil
        io.async { [weak self] in
            if job.loaded { Self.launchctl(["bootout", Self.domain, job.path]) }
            DispatchQueue.main.async {
                NSWorkspace.shared.recycle([URL(fileURLWithPath: job.path)]) { _, failure in
                    if let failure { self?.error = "\(job.label) could not be moved to the Trash: \(failure.localizedDescription)" }
                    self?.reload()
                }
            }
        }
    }

    func reveal(_ job: LaunchAgentJob) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.path)]) }
}

// MARK: - Views

protocol ScheduledDisplay: AnyObject { func reload() }

private let nextFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
    return formatter
}()

private func dotColor(_ job: LaunchAgentJob) -> NSColor { job.failed ? .systemRed : job.paused ? Palette.textTertiary : Palette.accent }

final class ScheduledCardView: NSView, ScheduledDisplay {
    private weak var module: ScheduledModule?
    private let list = NSStackView()
    private let empty = line("", size: 12, color: Palette.textTertiary)
    init(module: ScheduledModule) {
        self.module = module
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        embed(column([list, empty], spacing: 0), in: self, inset: 0)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(open)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Scheduled tasks. Opens the Scheduled tab.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func open() { module?.contextShell?.selectTab("scheduled") }

    func reload() {
        guard let module else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for job in module.visible.prefix(3) {
            let dot = FillView(fill: dotColor(job), radius: 3.5)
            size(dot, width: 7, height: 7)
            let detail = job.paused ? "Paused" : job.next.map { nextFormat.string(from: $0) } ?? job.schedule
            list.addArrangedSubview(row([dot, line(job.label, size: 12, color: Palette.textPrimary), line(detail, size: 11, color: Palette.textTertiary)], spacing: 7))
        }
        empty.stringValue = module.loadedOnce ? "No scheduled tasks of yours." : ""
        empty.isHidden = !module.visible.isEmpty
    }
}

final class ScheduledTabView: NSView, ScheduledDisplay {
    private weak var module: ScheduledModule?
    private let list = NSStackView()
    private let error = label("", size: 11, color: .systemRed)
    private let count = line("", size: 11, color: Palette.textTertiary)
    private let showApps: HoverButton
    private let emptyView: NSView

    init(module: ScheduledModule) {
        self.module = module
        showApps = HoverButton("Installed by apps", style: .chip) { [weak module] in module?.showAppAgents.toggle() }
        emptyView = placeholder(symbol: "clock.arrow.2.circlepath", title: "No scheduled tasks", detail: "Launch agents you add to ~/Library/LaunchAgents show up here.")
        super.init(frame: .zero)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        let refresh = HoverButton(symbol: "arrow.clockwise", style: .icon, symbolSize: 11, label: "Reload") { [weak module] in module?.reload() }
        let header = row([line("Launch agents", size: 13, weight: .semibold, color: Palette.textPrimary), count, spacer(), showApps, refresh], spacing: 8)
        error.preferredMaxLayoutWidth = 640
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        embed(list, in: document, inset: NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0), fill: true)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let stack = column([header, error, scroll], spacing: 8)
        embed(stack, in: self, inset: 0, fill: true)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor)
        ])
        embed(emptyView, in: self, inset: NSEdgeInsets(top: 40, left: 0, bottom: 0, right: 0), fill: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        let jobs = module.visible
        showApps.isSelectedLook = module.showAppAgents
        showApps.text = module.showAppAgents ? "Hide app agents" : "Show \(module.hiddenCount) from apps"
        showApps.isHidden = module.hiddenCount == 0
        count.stringValue = jobs.isEmpty ? "" : "\(jobs.count)"
        error.stringValue = module.error
        error.isHidden = module.error.isEmpty
        emptyView.isHidden = !jobs.isEmpty || !module.loadedOnce
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for job in jobs {
            let row = JobRow(job: job, module: module, confirming: module.confirming == job.label)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
}

private final class JobRow: FillView {
    init(job: LaunchAgentJob, module: ScheduledModule, confirming: Bool) {
        super.init(fill: Palette.card, stroke: job.failed ? NSColor.systemRed.withAlphaComponent(0.4) : Palette.stroke, radius: 10)
        let dot = FillView(fill: dotColor(job), radius: 4)
        size(dot, width: 8, height: 8)
        let title = line(job.label, size: 13, weight: .semibold, color: Palette.textPrimary)
        let meta = line(job.meta(formatter: nextFormat), size: 11, color: job.failed ? .systemRed : Palette.textTertiary)
        let program = line(job.program, size: 10, color: Palette.textTertiary)
        program.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let text = column([title, meta, program], spacing: 2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var buttons: [NSView]
        if confirming {
            buttons = [line("Move to Trash?", size: 11, color: Palette.textSecondary),
                       HoverButton("Delete", style: .accent) { [weak module] in module?.delete(job) },
                       HoverButton("Cancel", style: .plain) { [weak module] in module?.askDelete(nil) }]
        } else {
            buttons = [HoverButton(job.paused ? "Resume" : "Pause", style: .plain) { [weak module] in module?.setPaused(job, !job.paused) },
                       HoverButton(symbol: "folder", style: .icon, symbolSize: 11, label: "Show in Finder") { [weak module] in module?.reveal(job) },
                       HoverButton(symbol: "trash", style: .icon, symbolSize: 11, label: "Delete") { [weak module] in module?.askDelete(job) }]
        }
        let layout = row([dot, text, spacer()] + buttons, spacing: 8)
        embed(layout, in: self, inset: NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 8), fill: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(job.label). \(job.meta(formatter: nextFormat))")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
