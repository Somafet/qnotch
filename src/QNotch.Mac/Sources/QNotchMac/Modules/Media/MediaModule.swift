import AppKit
import QNotchMacCore

/// Now playing for the Music and Spotify apps (Windows MediaModule reads any app's session; macOS
/// has no public API for that). Track and play state come from the players' distributed
/// notifications, which need no permission. Controls, the current position and Music's artwork use
/// Apple Events: macOS asks once per player (Privacy & Security, Automation). A player that is not
/// running is never launched. Progress is interpolated once a second only while it is on screen.
final class MediaModule: NotchModule {
    private var context: ModuleContext!
    private(set) var sessions: [NowPlaying.Source: NowPlaying] = [:]
    private(set) var artwork: [NowPlaying.Source: NSImage] = [:]
    private(set) var selected: NowPlaying.Source?
    private(set) var message = ""
    private var visible = false
    private var queried = false
    private var tick: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let events = DispatchQueue(label: "qnotch.media.events", qos: .userInitiated)
    private let views = NSHashTable<AnyObject>.weakObjects()
    private let pills = NSHashTable<MediaPillView>.weakObjects()

    var current: NowPlaying? {
        if let selected, let session = sessions[selected] { return session }
        return sessions.values.first { $0.playing } ?? sessions.values.first
    }

    func initialize(_ context: ModuleContext) {
        self.context = context
        context.registries.cards.register(ViewContribution(id: "media", title: "Now playing", order: 20, symbol: "music.note", span: 2) { [unowned self] in
            self.track(MediaView(module: self, large: false))
        })
        context.registries.tabs.register(ViewContribution(id: "media", title: "Media", order: 10, symbol: "music.note") { [unowned self] in
            self.track(MediaView(module: self, large: true))
        })
        context.registries.segments.register(SegmentContribution(id: "media.pill", order: 5, slot: .leading, destination: .tab("media"), destinationLabel: "Open media") { [weak self] in
            let view = MediaPillView()
            self?.pills.add(view)
            view.update(self?.current, artwork: self?.current.flatMap { self?.artwork[$0.source] })
            return view
        })
        let distributed = DistributedNotificationCenter.default()
        for source in NowPlaying.Source.allCases {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(source.notification), object: nil, queue: .main) { [weak self] note in
                self?.received(note.userInfo ?? [:], from: source)
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if let source = NowPlaying.Source.allCases.first(where: { $0.rawValue == id }) { self?.sessions[source] = nil; self?.artwork[source] = nil; self?.changed() }
        }))
        if Runtime.diagnostics { seedDemo() }
    }

    private func track<V: NSView & MediaDisplay>(_ view: V) -> NSView {
        views.add(view)
        view.reload()
        return view
    }

    func setVisibility(panel: Bool, activeTab: String) {
        visible = panel && (activeTab == "home" || activeTab == "media")
        // The first look asks running players what they play (the notifications only come on a change).
        if visible, !queried, !Runtime.diagnostics { queried = true; NowPlaying.Source.allCases.forEach(query) }
        if visible, let session = current, session.playing { syncPosition(session.source) }
        scheduleTick()
    }

    func systemDidWake() {}

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        tick?.invalidate(); tick = nil
    }

    // MARK: Events

    private func received(_ info: [AnyHashable: Any], from source: NowPlaying.Source) {
        guard var session = NowPlaying.from(notification: info, source: source) else {
            sessions[source] = nil
            artwork[source] = nil
            return changed()
        }
        let previous = sessions[source]
        if session.position == nil, let previous, previous.trackID == session.trackID { session.position = previous.position(at: Date()) }
        sessions[source] = session
        if session.playing { selected = source }
        if previous?.trackID != session.trackID { artwork[source] = nil; loadArtwork(source) }
        if visible, session.position == nil || source == .music { syncPosition(source) }
        changed()
    }

    private func changed() {
        if let selected, sessions[selected] == nil { self.selected = nil }
        for case let view as MediaDisplay in views.allObjects { view.reload() }
        let shown = current
        pills.allObjects.forEach { $0.update(shown, artwork: shown.flatMap { artwork[$0.source] }) }
        context.shell?.segmentsChanged()
        scheduleTick()
    }

    /// Once a second, only while the card or tab is visible and something with a length plays.
    private func scheduleTick() {
        let needed = visible && (current.map { $0.playing && $0.duration != nil } ?? false)
        if needed, tick == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                for case let view as MediaDisplay in self?.views.allObjects ?? [] { view.tick() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            tick = timer
        } else if !needed { tick?.invalidate(); tick = nil }
    }

    func select(_ source: NowPlaying.Source) {
        selected = source
        changed()
    }

    // MARK: Apple Events

    private static func running(_ source: NowPlaying.Source) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).isEmpty
    }

    /// Runs on one serial queue; never targets a player that is not running (that would launch it).
    private func run(_ source: NowPlaying.Source, _ body: String, done: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        guard Self.running(source), !Runtime.diagnostics else { done?(nil); return }
        let script = "tell application id \"\(source.rawValue)\"\n\(body)\nend tell"
        events.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            DispatchQueue.main.async {
                if let code = error?[NSAppleScript.errorNumber] as? Int, code == -1743 {
                    self?.message = "QNotch may not control \(source.name). Allow it in System Settings, Privacy & Security, Automation."
                    self?.changed()
                } else if error == nil, self?.message.isEmpty == false {
                    self?.message = ""
                    self?.changed()
                }
                done?(error == nil ? result : nil)
            }
        }
    }

    /// Asks a running player for its current track (one Automation prompt the first time).
    private func query(_ source: NowPlaying.Source) {
        let body = source == .music
            ? "if player state is stopped then return {}\nreturn {name of current track, artist of current track, album of current track, (duration of current track) * 1000, player position, player state as string, (persistent ID of current track) as string}"
            : "if player state is stopped then return {}\nreturn {name of current track, artist of current track, album of current track, duration of current track, player position, player state as string, id of current track}"
        run(source, body) { [weak self] result in
            guard let self, let result, result.numberOfItems >= 7 else { return }
            func item(_ index: Int) -> NSAppleEventDescriptor? { result.atIndex(index) }
            let state = item(6)?.stringValue ?? ""
            let info: [String: Any] = ["Name": item(1)?.stringValue ?? "", "Artist": item(2)?.stringValue ?? "", "Album": item(3)?.stringValue ?? "",
                                       source == .music ? "Total Time" : "Duration": item(4)?.doubleValue ?? 0,
                                       "Playback Position": item(5)?.doubleValue ?? 0,
                                       "Player State": state.lowercased().contains("play") ? "Playing" : state.lowercased().contains("pause") ? "Paused" : "Stopped",
                                       "Track ID": item(7)?.stringValue ?? ""]
            self.received(info, from: source)
        }
    }

    private func syncPosition(_ source: NowPlaying.Source) {
        run(source, "return player position") { [weak self] result in
            guard let self, let position = result?.doubleValue, var session = self.sessions[source] else { return }
            session.position = position
            session.positionAt = Date()
            self.sessions[source] = session
            for case let view as MediaDisplay in self.views.allObjects { view.tick() }
        }
    }

    /// Music hands over the artwork itself; Spotify only offers a web address, which QNotch does not fetch.
    private func loadArtwork(_ source: NowPlaying.Source) {
        guard source == .music else { return }
        run(source, "return raw data of artwork 1 of current track") { [weak self] result in
            guard let self, let data = result?.data, let image = NSImage(data: data) else { return }
            image.size = NSSize(width: 128, height: 128)
            self.artwork[source] = image
            self.changed()
        }
    }

    func playPause() {
        guard let session = current else { return }
        sessions[session.source]?.playing.toggle()
        sessions[session.source]?.position = session.position(at: Date())
        sessions[session.source]?.positionAt = Date()
        changed()
        run(session.source, "playpause")
    }

    func next() { if let session = current { run(session.source, "next track") } }
    func previous() { if let session = current { run(session.source, "previous track") } }

    func seek(to seconds: Double) {
        guard let session = current else { return }
        sessions[session.source]?.position = seconds
        sessions[session.source]?.positionAt = Date()
        run(session.source, "set player position to \(seconds)")
    }

    /// Smoke snapshots only: back to "Nothing playing".
    func clearForSmoke() {
        sessions = [:]
        selected = nil
        changed()
    }

    private func seedDemo() {
        sessions[.music] = NowPlaying(source: .music, title: "Teardrop", artist: "Massive Attack", album: "Mezzanine", playing: true,
                                      duration: 330, position: 84, positionAt: Date(), trackID: "demo")
        selected = .music
        visible = false
    }
}

// MARK: - Views

protocol MediaDisplay: AnyObject {
    func reload()
    func tick()
}

private func playerIcon(_ source: NowPlaying.Source) -> NSImage {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.rawValue).map { NSWorkspace.shared.icon(forFile: $0.path) }
        ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
}

/// A small artwork tile and the title, left of the notch, only while something plays.
final class MediaPillView: NSStackView {
    private let art = NSImageView()
    private let title = line("", size: 12, weight: .semibold, color: Palette.textPrimary)
    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        size(art, width: 16, height: 16)
        art.wantsLayer = true
        art.layer?.cornerRadius = 3
        art.layer?.masksToBounds = true
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 96).isActive = true
        [art, title].forEach(addArrangedSubview)
        identifier = NSUserInterfaceItemIdentifier("media-segment")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ session: NowPlaying?, artwork: NSImage?) {
        isHidden = !(session?.playing ?? false)
        guard let session else { return }
        art.image = artwork ?? playerIcon(session.source)
        title.stringValue = session.title
        setAccessibilityLabel("Now playing: \(session.title), \(session.subtitle)")
    }
}

final class MediaView: NSView, MediaDisplay, HomeCardSizing {
    private weak var module: MediaModule?
    private let large: Bool
    private var compact = false
    private var infoMinimum: NSLayoutConstraint!
    private let art = NSImageView()
    private let title: NSTextField
    private let artist: NSTextField
    private let album = line("", size: 12, color: Palette.textTertiary)
    private let elapsed = line("", size: 10, color: Palette.textTertiary)
    private let total = line("", size: 10, color: Palette.textTertiary)
    private let seek = LevelSlider(label: "Position")
    private let chips = NSStackView()
    private let play: HoverButton
    private let content: NSView
    /// Nothing playing (Windows MediaViews.Nothing): a glyph, a title and a hint, centered.
    private let empty: NSStackView
    private let emptyDetail: NSTextField

    init(module: MediaModule, large: Bool) {
        self.module = module
        self.large = large
        title = line("", size: large ? 22 : 15, weight: .semibold, color: Palette.textPrimary)
        artist = line("", size: large ? 14 : 12, color: Palette.textSecondary)
        play = HoverButton(symbol: "play.fill", style: large ? .accentCircle : .icon, symbolSize: large ? 17 : 15, label: "Play") { [weak module] in module?.playPause() }
        emptyDetail = label(Self.emptyHint(large: large), size: 12, color: Palette.textTertiary)
        emptyDetail.alignment = .center
        emptyDetail.preferredMaxLayoutWidth = 300
        let glyph = symbol("music.note", size: large ? 26 : 22, weight: .light, color: Palette.textTertiary)
        empty = column([glyph, line("Nothing playing", size: large ? 15 : 14, weight: .semibold, color: Palette.textPrimary), emptyDetail],
                       spacing: 4, alignment: .centerX)
        empty.setCustomSpacing(8, after: glyph)
        let previous = HoverButton(symbol: "backward.fill", style: .icon, symbolSize: 13, label: "Previous") { [weak module] in module?.previous() }
        let next = HoverButton(symbol: "forward.fill", style: .icon, symbolSize: 13, label: "Next") { [weak module] in module?.next() }
        let side: CGFloat = large ? 200 : 74
        size(art, width: side, height: side)
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = large ? 14 : 9
        art.layer?.masksToBounds = true
        chips.orientation = .horizontal
        chips.spacing = 4
        seek.step = 5
        elapsed.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        total.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let times = large ? row([elapsed, spacer(), total], spacing: 4) : row([elapsed, seek, total], spacing: 6)
        let controls = row([previous, play, next], spacing: 10)
        let info = column(large ? [chips, title, artist, album, seek, times, controls] : [title, artist, times, row([chips, spacer(), previous, play, next], spacing: 2)], spacing: large ? 6 : 2)
        if large { info.setCustomSpacing(16, after: album); seek.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true }
        else { info.setCustomSpacing(6, after: artist) }
        times.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true
        if let last = info.arrangedSubviews.last, !large { last.widthAnchor.constraint(equalTo: info.widthAnchor).isActive = true }
        content = row([art, info], spacing: large ? 24 : 14)
        (content as? NSStackView)?.alignment = .centerY
        super.init(frame: .zero)
        seek.changed = { [weak module] value in module?.seek(to: value) }
        embed(content, in: self, inset: large ? NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20) : NSEdgeInsetsZero, fill: !large)
        infoMinimum = info.widthAnchor.constraint(greaterThanOrEqualToConstant: large ? 360 : 250)
        infoMinimum.isActive = true
        if !large {
            for field in [title, artist] {
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                field.widthAnchor.constraint(lessThanOrEqualTo: info.widthAnchor).isActive = true
            }
        }
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)])
    }

    func setHomeCardSize(_ size: HomeCardSize) {
        guard !large else { return }
        compact = size == .small
        art.isHidden = compact
        chips.isHidden = compact
        infoMinimum.constant = compact ? 0 : 250
        emptyDetail.preferredMaxLayoutWidth = compact ? 180 : 300
        tick()
    }

    private static func emptyHint(large: Bool) -> String {
        large ? "Play something in Music or Spotify and it shows up here." : "Play something in Music or Spotify."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let module else { return }
        let session = module.current
        content.isHidden = session == nil
        empty.isHidden = session != nil
        emptyDetail.stringValue = module.message.isEmpty ? Self.emptyHint(large: large) : module.message
        guard let session else { return }
        art.image = module.artwork[session.source] ?? playerIcon(session.source)
        title.stringValue = session.title
        artist.stringValue = session.subtitle
        album.stringValue = session.playing ? session.album : [session.album, "Paused"].filter { !$0.isEmpty }.joined(separator: " · ")
        play.setSymbol(session.playing ? "pause.fill" : "play.fill", size: large ? 17 : 14, label: session.playing ? "Pause" : "Play")
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if module.sessions.count > 1 {
            for source in NowPlaying.Source.allCases where module.sessions[source] != nil {
                let chip = HoverButton(source.name, style: .chip) { [weak module] in module?.select(source) }
                chip.isSelectedLook = source == session.source
                chips.addArrangedSubview(chip)
            }
        }
        if !module.message.isEmpty { album.stringValue = module.message }
        tick()
    }

    func tick() {
        guard let session = module?.current else { return }
        let hasTimeline = session.duration != nil
        seek.isHidden = !hasTimeline
        elapsed.isHidden = !hasTimeline
        total.isHidden = !hasTimeline || compact
        guard let duration = session.duration else { return }
        let position = session.position(at: Date()) ?? 0
        seek.maxValue = duration
        seek.value = position
        elapsed.stringValue = NowPlaying.time(position)
        total.stringValue = NowPlaying.time(duration)
    }
}
