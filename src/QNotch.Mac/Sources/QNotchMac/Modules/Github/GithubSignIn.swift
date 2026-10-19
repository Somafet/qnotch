import AppKit
import QNotchMacCore

/// QNotch's GitHub OAuth App, with Device Flow enabled. A device-flow client ID is public and there
/// is no client secret. While it is empty, every Sign in with GitHub button is hidden and the token
/// box is shown instead.
enum GithubOAuth {
    static let clientId = ""
    static var available: Bool { !clientId.isEmpty }
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

    init(look: Look, save: @escaping (String) -> Bool) {
        self.look = look
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
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        buttons.orientation = .horizontal
        buttons.spacing = 8
        [code, message, buttons].forEach(addArrangedSubview)
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        timer?.invalidate()
        task?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Polling runs only while the sign-in UI is on screen.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window else { cancel(); return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.cancel()
        }
    }

    var isBusy: Bool {
        switch state {
        case .requesting, .waiting, .checking: return true
        default: return false
        }
    }

    // MARK: Flow

    func begin() {
        guard GithubOAuth.available, !Runtime.diagnostics else { return }
        stop()
        let current = generation
        state = .requesting
        send(GithubDeviceFlow.codeRequest(clientID: GithubOAuth.clientId)) { [weak self] status, body, failed in
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

    func cancel() {
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
        send(GithubDeviceFlow.tokenRequest(clientID: GithubOAuth.clientId, deviceCode: flow.deviceCode)) { [weak self] status, body, failed in
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

    private func copyAndOpen() {
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
        message.stringValue = text
        message.isHidden = text.isEmpty
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions.forEach(buttons.addArrangedSubview)
        buttons.isHidden = actions.isEmpty
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

    init(context: ModuleSetupContext) {
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
        tokenBox = row([field, save], spacing: 8)
        addArrangedSubview(status)
        if GithubOAuth.available {
            let signIn = GithubSignInView(look: .notch) { [weak self] token in self?.store(token) ?? false }
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

    private func saveToken() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        note.isHidden = false
        guard !value.isEmpty else { note.stringValue = "Enter a token first."; return }
        guard store(value) else { note.stringValue = "The Keychain refused the token."; return }
        field.stringValue = ""
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

    private func show(login: String?) {
        status.stringValue = login.map { $0.isEmpty ? "Connected." : "Connected as @\($0)." } ?? "Token saved."
        signIn?.isHidden = true
        tokenBox.isHidden = true
        note.isHidden = true
    }
}
