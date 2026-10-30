import AppKit
import QNotchMacCore

/// QNotch's GitHub OAuth App, with Device Flow enabled and token expiry off (no refresh tokens).
/// A device-flow client ID is public and there is no client secret. Without one, every Sign in
/// with GitHub button is hidden and the token box is shown instead.
enum GithubOAuth {
    static let clientId = "Ov23liS199CVpbrlXUlC"
    static var available: Bool { isAvailable(clientId: clientId) }
    static func isAvailable(clientId: String) -> Bool { !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Sign in with GitHub through the OAuth device flow (spec/onboarding.md): shows the code, copies
/// it and opens GitHub, then polls at GitHub's interval only while the view is in a window. Cancel,
/// leaving the page, closing the window or the code expiring stops it. The token, device code and
/// user code are never logged.
final class GithubSignInView: NSStackView {
    enum Look { case notch, settings }

    private enum State {
        case idle
        case requesting
        case waiting(GithubDeviceFlow.Code)
        case checking
        case failed(String)
        case connected(String)
    }

    private let look: Look
    /// Stores the token where a pasted one goes (the Keychain, through the running module if any).
    private let save: (String) -> Bool
    /// The account's login once the token checked out.
    var connected: ((String) -> Void)?
    /// Shown beside Sign in with GitHub (the tour's "Use a token instead").
    var extras: [NSView] = [] { didSet { render() } }
    private let message: NSTextField
    private let code: NSTextField
    private let buttons = NSStackView()
    private var state = State.idle { didSet { render() } }
    private var generation = 0
    private var flow: GithubDeviceFlow.Code?
    private var interval: TimeInterval = 5
    private var deadline = Date.distantPast
    private var task: URLSessionDataTask?
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    /// A dot that pulses beside "Waiting for you…" only while polling and on screen.
    private let pulse: FillView
    private let waiting: NSStackView
    private var wasWaiting = false

    private let clientId: String

    init(look: Look, clientId: String = GithubOAuth.clientId, save: @escaping (String) -> Bool) {
        self.look = look
        self.clientId = clientId
        self.save = save
        let primary = look == .notch ? Palette.textPrimary : NSColor.labelColor
        let secondary = look == .notch ? Palette.textSecondary : NSColor.secondaryLabelColor
        let message = label("", size: look == .notch ? 12 : 11, color: secondary)
        message.preferredMaxLayoutWidth = 380
        let code = NSTextField(labelWithString: "")
        code.font = .monospacedSystemFont(ofSize: 24, weight: .semibold)
        code.textColor = primary
        code.isSelectable = true
        self.message = message
        self.code = code
        let pulse = FillView(fill: look == .notch ? Palette.accent : NSColor.controlAccentColor, radius: 3)
        size(pulse, width: 6, height: 6)
        self.pulse = pulse
        waiting = row([pulse, message], spacing: 7)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        buttons.orientation = .horizontal
        buttons.spacing = 8
        [code, waiting, buttons].forEach(addArrangedSubview)
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        task?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// Polling runs only while the sign-in UI is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in [closeObserver, occlusionObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        closeObserver = nil
        occlusionObserver = nil
        guard let window else { cancel(); updatePulse(); return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.cancel()
        }
        occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            self?.updatePulse()
        }
        updatePulse()
    }

    /// The waiting dot's loop exists only while polling with the window visible; otherwise it is removed.
    private func updatePulse() {
        let polling: Bool
        if case .waiting = state { polling = true } else { polling = false }
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard let layer = pulse.layer else { return }
        guard polling, visible, Motion.moves else { layer.removeAnimation(forKey: "pulse"); return }
        guard layer.animation(forKey: "pulse") == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.25
        fade.duration = 0.75
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "pulse")
    }

    var isBusy: Bool {
        switch state {
        case .requesting, .waiting, .checking: return true
        default: return false
        }
    }

    // MARK: Flow

    func begin() { Analytics.record("github", "connect");
        guard GithubOAuth.isAvailable(clientId: clientId), !Runtime.diagnostics else { return }
        stop()
        let current = generation
        state = .requesting
        send(GithubDeviceFlow.codeRequest(clientID: clientId)) { [weak self] status, body, failed in
            guard let self, self.generation == current else { return }
            do {
                let flow = try GithubDeviceFlow.parseCode(status: status, body: body, transportFailed: failed)
                self.flow = flow
                self.interval = flow.interval
                self.deadline = Date().addingTimeInterval(flow.expiresIn)
                self.state = .waiting(flow)
                self.schedulePoll()
            } catch {
                self.state = .failed((error as? GithubError)?.text ?? "GitHub sent an unexpected response.")
            }
        }
    }

    func cancel() { Analytics.record("github", "cancel_connect");
        guard isBusy else { return }
        stop()
        state = .idle
    }

    /// Ends any request or wait; answers that arrive later are ignored.
    private func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        flow = nil
    }

    private func send(_ request: URLRequest, done: @escaping (Int?, Data?, Bool) -> Void) {
        let task = GithubModule.checkSession.dataTask(with: request) { body, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            DispatchQueue.main.async { done(status, body, error != nil) }
        }
        self.task = task
        task.resume()
    }

    private func schedulePoll() {
        timer?.invalidate()
        let current = generation
        // Never past the code's lifetime: the last wait ends when it expires.
        let wait = max(1, min(interval, deadline.timeIntervalSinceNow + 1))
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.poll(current) }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll(_ current: Int) {
        guard generation == current, let flow, window != nil else { return }
        guard Date() < deadline else { return fail(GithubDeviceFlow.expiredMessage) }
        send(GithubDeviceFlow.tokenRequest(clientID: clientId, deviceCode: flow.deviceCode)) { [weak self] status, body, failed in
            guard let self, self.generation == current else { return }
            let answer = GithubDeviceFlow.parsePoll(status: status, body: body, transportFailed: failed)
            switch answer {
            case .pending:
                self.schedulePoll()
            case .slowDown:
                self.interval = GithubDeviceFlow.nextInterval(after: answer, current: self.interval)
                self.schedulePoll()
            case .expired: self.fail(GithubDeviceFlow.expiredMessage)
            case .denied: self.fail(GithubDeviceFlow.deniedMessage)
            case .failed(let text): self.fail(text)
            case .token(let token): self.complete(token)
            }
        }
    }

    private func fail(_ text: String) {
        stop()
        state = .failed(text)
    }

    private func complete(_ token: String) {
        stop()
        guard save(token) else { return fail("The Keychain refused the token.") }
        let current = generation
        state = .checking
        GithubModule.login(token: token) { [weak self] result in
            guard let self, self.generation == current else { return }
            switch result {
            case .success(let login):
                self.state = .connected(login)
                self.connected?(login)
            case .failure(let failure): self.state = .failed(failure.text)
            }
        }
    }

    private func copyAndOpen() { Analytics.record("github", "open_authorization");
        guard let flow else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(flow.userCode, forType: .string)
        NSWorkspace.shared.open(flow.verificationURL)
    }

    // MARK: Views

    private func button(_ title: String, primary: Bool = false, _ action: @escaping () -> Void) -> NSView {
        switch look {
        case .notch: return HoverButton(title, style: primary ? .accent : .plain, action: action)
        case .settings: return actionButton(title, action)
        }
    }

    private func render() {
        var actions: [NSView] = []
        var text = ""
        code.isHidden = true
        switch state {
        case .idle:
            actions = [button("Sign in with GitHub", primary: true) { [weak self] in self?.begin() }] + extras
        case .requesting:
            text = "Asking GitHub for a code…"
            actions = [button("Cancel") { [weak self] in self?.cancel() }]
        case .waiting(let flow):
            code.stringValue = flow.userCode
            code.setAccessibilityLabel("Code " + flow.userCode.map { String($0) }.joined(separator: " "))
            code.isHidden = false
            text = "Waiting for you to approve QNotch on GitHub…"
            actions = [button("Copy code and open GitHub", primary: true) { [weak self] in self?.copyAndOpen() },
                       button("Cancel") { [weak self] in self?.cancel() }]
        case .checking:
            text = "Signed in. Checking your account…"
        case .failed(let failure):
            text = failure
            actions = [button("Try again", primary: true) { [weak self] in self?.begin() }] + extras
        case .connected(let login):
            text = "Connected as @\(login)."
        }
        let isWaiting: Bool
        if case .waiting = state { isWaiting = true } else { isWaiting = false }
        if message.stringValue != text, !text.isEmpty { Motion.crossfade(message) }
        message.stringValue = text
        waiting.isHidden = text.isEmpty
        pulse.isHidden = !isWaiting
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in actions {
            (action as? HoverButton)?.pressScale = 0.97
            buttons.addArrangedSubview(action)
        }
        buttons.isHidden = actions.isEmpty
        // The code panel expands once, when the code arrives.
        if isWaiting, !wasWaiting {
            layoutSubtreeIfNeeded()
            Motion.enter(code, duration: 0.28, scale: 0.86)
            Motion.enter(waiting, delay: 0.08, duration: 0.22, up: 4)
            Motion.enter(buttons, delay: 0.12, duration: 0.22, up: 4)
        }
        wasWaiting = isWaiting
        updatePulse()
    }
}

extension GithubModule {
    /// The welcome tour's Connect row: Sign in with GitHub, or the token box.
    static func setupRow(_ context: ModuleSetupContext) -> NSView? { GithubSetupView(context: context) }
}

/// The tour's GitHub row: status, Sign in with GitHub and "Use a token instead" (the token box
/// alone while there is no OAuth client ID).
final class GithubSetupView: NSStackView {
    private let context: ModuleSetupContext
    private let status = setupStatus("Not connected.")
    private var signIn: GithubSignInView?
    private let field = NSSecureTextField()
    private let note = setupStatus("")
    private var tokenBox = NSStackView()
    private let check = symbol("checkmark.circle.fill", size: 13, weight: .semibold, color: .systemGreen)
    private let grid = ContributionWave()

    /// Sign in with GitHub is offered (an OAuth client ID is set).
    var offersSignIn: Bool { signIn != nil }
    /// The token box shows without asking for it.
    var showsTokenBox: Bool { !tokenBox.isHidden }

    init(context: ModuleSetupContext, clientId: String = GithubOAuth.clientId) {
        self.context = context
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        field.placeholderString = "ghp_…"
        field.setAccessibilityLabel("Personal access token")
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        field.onAction { [weak self] in self?.saveToken() }
        let save = HoverButton("Save Token", style: .plain) { [weak self] in self?.saveToken() }
        save.pressScale = 0.97
        tokenBox = row([field, save], spacing: 8)
        // The contribution grid sits at the right; the rows keep clear of it.
        edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: ContributionWave.width + 16)
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([grid.topAnchor.constraint(equalTo: topAnchor, constant: -18), grid.trailingAnchor.constraint(equalTo: trailingAnchor)])
        check.isHidden = true
        addArrangedSubview(row([check, status], spacing: 5))
        if GithubOAuth.isAvailable(clientId: clientId) {
            let signIn = GithubSignInView(look: .notch, clientId: clientId) { [weak self] token in self?.store(token) ?? false }
            signIn.connected = { [weak self] login in self?.show(login: login) }
            signIn.extras = [HoverButton("Use a token instead", style: .chip) { [weak self] in
                self?.tokenBox.isHidden = false
                self?.window?.makeFirstResponder(self?.field)
            }]
            self.signIn = signIn
            addArrangedSubview(signIn)
            tokenBox.isHidden = true
        }
        addArrangedSubview(tokenBox)
        note.isHidden = true
        addArrangedSubview(note)
        loadStatus()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var running: GithubModule? { context.running() as? GithubModule }

    private func loadStatus() {
        if let running {
            guard running.hasToken else { return }
            return show(login: running.data?.login)
        }
        // A token from an earlier install; read off the main thread, as the module does.
        let cache = context.settings.directory.appendingPathComponent("github-cache.json")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard Keychain.read(GithubModule.tokenService) != nil else { return }
            let login = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode(GithubData.self, from: $0) }?.login
            DispatchQueue.main.async { self?.show(login: login) }
        }
    }

    /// The same storage as Settings: through the running module, else straight into the Keychain.
    private func store(_ token: String) -> Bool {
        if let running { return running.save(token) }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && Keychain.write(trimmed, service: GithubModule.tokenService)
    }

    private func saveToken() { Analytics.record("github", "connect");
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        note.isHidden = false
        guard !value.isEmpty else { note.stringValue = "Enter a token first."; return }
        guard store(value) else { note.stringValue = "The Keychain refused the token."; return }
        field.stringValue = ""
        Motion.crossfade(status)
        status.stringValue = "Token saved."
        guard !Runtime.diagnostics else { note.isHidden = true; return }
        note.stringValue = "Checking the token…"
        GithubModule.login(token: value) { [weak self] result in
            switch result {
            case .success(let login): self?.show(login: login)
            case .failure(let failure): self?.note.stringValue = failure.text
            }
        }
    }

    /// Connected: the status crossfades to green, the check pops and the grid fills again.
    private func show(login: String?) {
        Motion.crossfade(status)
        status.stringValue = login.map { $0.isEmpty ? "Connected." : "Connected as @\($0)." } ?? "Token saved."
        status.textColor = .systemGreen
        signIn?.isHidden = true
        tokenBox.isHidden = true
        note.isHidden = true
        check.isHidden = false
        guard window != nil else { return }
        layoutSubtreeIfNeeded()
        Motion.pop(check)
        grid.wave()
    }
}

/// A small contribution grid for the tour's GitHub row. It fills in a diagonal wave (about
/// 400 ms) each time it appears and again after a successful sign-in. Plain layers; nothing runs
/// between waves.
final class ContributionWave: NSView {
    private static let columns = 16, rows = 7
    private static let cell: CGFloat = 7, gap: CGFloat = 2
    static let width = CGFloat(columns) * (cell + gap) - gap
    private static let height = CGFloat(rows) * (cell + gap) - gap
    private var cells: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        var seed: UInt64 = 7
        for _ in 0..<(Self.columns * Self.rows) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let roll = Int(seed >> 60)
            let level = roll < 5 ? 0 : min(4, (roll - 5) / 3 + 1)
            let cell = CALayer()
            cell.cornerRadius = 1.5
            cell.backgroundColor = ContributionGraph.color(level).cgColor
            layer?.addSublayer(cell)
            cells.append(cell)
        }
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (offset, cell) in cells.enumerated() {
            let column = offset % Self.columns, row = offset / Self.columns
            let top = CGFloat(row) * (Self.cell + Self.gap)
            cell.frame = CGRect(x: CGFloat(column) * (Self.cell + Self.gap), y: isFlipped ? top : bounds.height - top - Self.cell,
                                width: Self.cell, height: Self.cell)
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { wave() }
    }

    /// Cell by cell from the top-left corner; with reduced motion one short fade.
    func wave() {
        guard Motion.fades, let layer else { return }
        guard Motion.moves else { return Motion.enter(self, duration: Motion.crossfadeDuration) }
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let steps = Double(Self.columns + Self.rows - 2)
        for (offset, cell) in cells.enumerated() {
            let diagonal = Double(offset % Self.columns + offset / Self.columns)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: CATransform3DMakeScale(0.3, 0.3, 1))
            grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            for animation in [fade, grow] {
                animation.beginTime = now + diagonal / steps * 0.4
                animation.duration = 0.16
                animation.timingFunction = Motion.easeOut
                animation.fillMode = .backwards
                cell.add(animation, forKey: "wave." + (animation.keyPath ?? ""))
            }
        }
    }
}
