import XCTest
import AppKit
import Darwin
@testable import QNotchMac
@testable import QNotchMacCore

final class TerminalTests: XCTestCase {
    func testTerminalRequiresExplicitOptInAcrossOldAndNewSettings() throws {
        for settings in [GeneralSettings(), try JSONDecoder().decode(GeneralSettings.self, from: Data(#"{"disabledModules":[]}"#.utf8))] {
            XCTAssertFalse(settings.isEnabled("terminal"))
            var changed = settings
            changed.setEnabled("terminal", true)
            XCTAssertTrue(changed.isEnabled("terminal"))
            let saved = try JSONDecoder().decode(GeneralSettings.self, from: JSONEncoder().encode(changed))
            XCTAssertTrue(saved.isEnabled("terminal"))
            changed.setEnabled("terminal", false)
            XCTAssertFalse(changed.isEnabled("terminal"))
            XCTAssertTrue(changed.isEnabled("timer"))
        }
        XCTAssertTrue(ModuleList.all.contains { $0.id == "terminal" })
    }

    func testSetupCodeCarriesOptInOnlyInMacSection() throws {
        func snapshot(_ general: GeneralSettings) -> SetupCode.Snapshot {
            SetupCode.Snapshot(general: general, gameMode: GameModeSettings(), timer: TimerSettings(), weather: WeatherSettings(),
                               notifications: NotificationSettings(), ai: AiSettings(), agents: AgentsSettings())
        }
        var settings = GeneralSettings()
        settings.setEnabled("terminal", true)
        let plan = try SetupCode.read(SetupCode.export(snapshot(settings)), current: snapshot(GeneralSettings()), modules: ["terminal"])
        XCTAssertTrue(plan.result.general.isEnabled("terminal"))
        XCTAssertEqual(plan.turnsOn, ["terminal"])
        XCTAssertFalse(ModuleList.make(disabled: []).contains { $0 is TerminalModule })
    }

    func testScreenRendersCarriageReturnEditingColorsAndSplitUTF8() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("hello\rOK\u{1B}[K\r\n\u{1B}[31;1mred\u{1B}[0m ".utf8))
        let unicode = Array("é界".utf8)
        screen.feed(Data(unicode.prefix(1))); screen.feed(Data(unicode.dropFirst(1)))
        XCTAssertEqual(TerminalScreen.text(screen.grid[0]), "OK")
        XCTAssertEqual(TerminalScreen.text(screen.grid[1]), "red é界")
        XCTAssertEqual(screen.grid[1][0].style.foreground, 1)
        XCTAssertTrue(screen.grid[1][0].style.bold)
        XCTAssertTrue(screen.grid[1][6].continuation)
        screen.feed(Data("\u{1B}[1;2H!\u{1B}[2P".utf8))
        XCTAssertEqual(TerminalScreen.text(screen.grid[0]), "O!")
    }

    func testScreenBoundedScrollbackAlternateScreenResizeAndHostileSequences() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data(String(repeating: "line\r\n", count: 900).utf8))
        XCTAssertEqual(screen.history.count, 500)
        let primary = screen.grid
        screen.feed(Data("\u{1B}[?1049h\u{1B}[2Jalternate".utf8))
        XCTAssertFalse(screen.plainText.contains("line"))
        screen.feed(Data("\u{1B}[?1049l".utf8))
        XCTAssertEqual(screen.grid, primary)
        screen.feed(Data(("\u{1B}]52;c;" + String(repeating: "x", count: 30_000) + "\u{7}\u{1B}[" + String(repeating: "9;", count: 500) + "H").utf8))
        screen.resize(columns: 1_000, rows: 0)
        XCTAssertEqual(screen.columns, 240); XCTAssertEqual(screen.rows, 4)
        XCTAssertEqual(screen.grid.count, 4); XCTAssertTrue(screen.grid.allSatisfy { $0.count == 240 })
        XCTAssertLessThanOrEqual(screen.x, 239); XCTAssertLessThanOrEqual(screen.y, 3)
        XCTAssertLessThanOrEqual(screen.history.count, 500)
    }

    func testColorChangesPreservePendingWrapAndCombiningMarksStayBounded() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data((String(repeating: "x", count: 20) + "\u{1B}[31mY").utf8))
        XCTAssertEqual(screen.grid[1][0].text, "Y")
        screen.feed(Data(String(repeating: "\u{301}", count: 10_000).utf8))
        XCTAssertLessThanOrEqual(screen.grid[1][0].text.unicodeScalars.count, 8)
    }

    func testScreenQueriesModesAndScrollRegion() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        var replies = Data()
        screen.reply = { replies.append($0) }
        screen.feed(Data("\u{1B}[2;3H\u{1B}[6n\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l".utf8))
        XCTAssertEqual(replies, Data("\u{1B}[2;3R".utf8))
        XCTAssertTrue(screen.applicationCursor); XCTAssertTrue(screen.bracketedPaste); XCTAssertFalse(screen.cursorVisible)
        screen.feed(Data("\u{1B}[1;1Hheader\u{1B}[2;4r\u{1B}[4;1Hbottom\r\n".utf8))
        XCTAssertEqual(TerminalScreen.text(screen.grid[0]), "header")
        XCTAssertTrue(screen.history.isEmpty)
    }

    func testKeyEncodingInterruptEscapeArrowsAndDelete() throws {
        func event(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                         context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(TerminalCanvas.key(try event(8, "c", .control), applicationCursor: false), Data([3]))
        XCTAssertEqual(TerminalCanvas.key(try event(53, "\u{1B}"), applicationCursor: false), Data([27]))
        XCTAssertEqual(TerminalCanvas.key(try event(126, ""), applicationCursor: true), Data("\u{1B}OA".utf8))
        XCTAssertEqual(TerminalCanvas.key(try event(117, ""), applicationCursor: false), Data("\u{1B}[3~".utf8))
    }

    // Real PTY tests are deliberately separate from UI diagnostics. Use a temporary HOME and
    // /bin/sh, never the user's shell startup files, and stop only the directly owned child.
    func testRealPTYIsControllingTerminalStartsInHomeAndResizes() throws {
        XCTAssertTrue(Thread.isMainThread)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = TerminalSession()
        defer { session.stop() }
        let initial = expectation(description: "real tty home and dimensions")
        let resized = expectation(description: "PTY resize reaches shell")
        var output = "", gotInitial = false, gotResize = false
        session.output = { data in
            output += String(decoding: data, as: UTF8.self)
            if !gotInitial, output.contains("TTY_OK"), output.contains(home.path), output.contains("19 91") {
                gotInitial = true; initial.fulfill()
            }
            if !gotResize, output.contains("23 101") { gotResize = true; resized.fulfill() }
        }
        try session.start(shell: "/bin/sh", home: home.path, columns: 91, rows: 19)
        session.send(Data("test -t 0 && test -t 1 && test -t 2 && printf 'TTY_%s\\n' OK; pwd; stty size\r".utf8))
        wait(for: [initial], timeout: 8)
        session.resize(columns: 101, rows: 23)
        session.send(Data("stty size\r".utf8))
        wait(for: [resized], timeout: 5)
        XCTAssertGreaterThan(session.pid, 1)
        XCTAssertEqual(getsid(session.pid), session.pid)
        session.stop()
        XCTAssertTrue(session.reaped)
        XCTAssertEqual(session.master, -1)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(session.pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
        session.stop() // Idempotent; never signals a reused pid.
    }

    func testPTYControlCInterruptsForegroundJobAndKeepsShellAlive() throws {
        let session = TerminalSession()
        defer { session.stop() }
        let sleeping = expectation(description: "foreground sleep started")
        let interrupted = expectation(description: "shell survives Ctrl-C")
        let prompt = expectation(description: "shell is ready after interrupt")
        var output = "", started = false, finished = false, ready = false
        session.output = { data in
            output += String(decoding: data, as: UTF8.self)
            if !started, output.contains("JOB_STARTED") { started = true; sleeping.fulfill() }
            if !finished, output.contains("INTERRUPT_OK") { finished = true; interrupted.fulfill() }
            if !ready, output.contains("PTY_READY> ") { ready = true; prompt.fulfill() }
        }
        try session.start(shell: "/bin/sh", home: NSTemporaryDirectory(), columns: 80, rows: 18)
        session.send(Data("PS1='PTY_''READY> '; /bin/sh -c \"printf 'JOB_%s\\n' STARTED; exec sleep 30\"\r".utf8))
        wait(for: [sleeping], timeout: 8)
        let deadline = Date().addingTimeInterval(3)
        while tcgetpgrp(session.master) == session.pid, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(tcgetpgrp(session.master), session.pid, "Interrupt must target the foreground job, not the shell")
        session.send(Data([3]))
        // Wait for readline to restore tty modes; typing while it flushes after SIGINT can
        // legitimately discard input. The split PS1 token cannot match the command echo.
        wait(for: [prompt], timeout: 8)
        session.send(Data("printf 'INTERRUPT_%s\\n' OK\r".utf8))
        wait(for: [interrupted], timeout: 8)
        XCTAssertEqual(kill(session.pid, 0), 0)
        session.stop()
        XCTAssertTrue(session.reaped)
    }

    func testStoppingSessionKillsBackgroundJobsAndLeavesAnotherSessionAlone() throws {
        let session = TerminalSession(), other = TerminalSession()
        defer { session.stop(); other.stop() }
        let spawned = expectation(description: "owned background job pid")
        var output = "", job: pid_t?
        session.output = { data in
            output += String(decoding: data, as: UTF8.self)
            if job == nil, let match = output.range(of: #"OWNED_PID:[0-9]+"#, options: .regularExpression) {
                job = Int32(output[match].dropFirst("OWNED_PID:".count)); spawned.fulfill()
            }
        }
        try session.start(shell: "/bin/sh", home: NSTemporaryDirectory(), columns: 80, rows: 18)
        try other.start(shell: "/bin/sh", home: NSTemporaryDirectory(), columns: 80, rows: 18)
        session.send(Data("set +H\rsleep 30 & printf 'OWNED_PID:%s\\n' \"$!\"\r".utf8))
        wait(for: [spawned], timeout: 8)
        let child = try XCTUnwrap(job, "PTY output: \(output)")
        XCTAssertEqual(getsid(child), session.pid)
        let started = Date()
        session.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "Closing the master before waitpid must not hang")
        XCTAssertTrue(session.reaped)
        // A killed descendant can briefly remain a zombie awaiting launchd; it cannot run.
        var info = proc_bsdinfo()
        let count = proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        XCTAssertTrue(count == 0 || info.pbi_status == 5, "Owned background job remains alive")
        XCTAssertEqual(kill(other.pid, 0), 0)
        XCTAssertFalse(other.reaped)
    }

    func testPTYDrainsBufferedOutputBeforeReapingNaturalExit() throws {
        let session = TerminalSession()
        defer { session.stop() }
        let ended = expectation(description: "shell exit drains trailing output")
        var output = Data()
        session.output = { output.append($0) }
        session.ended = { _ in ended.fulfill() }
        try session.start(shell: "/bin/sh", home: NSTemporaryDirectory(), columns: 80, rows: 18)
        session.send(Data("head -c 32768 /dev/zero | tr '\\0' X; printf 'TAIL_%s\\n' DONE; exit\r".utf8))
        wait(for: [ended], timeout: 8)
        XCTAssertTrue(session.reaped)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("TAIL_DONE"))
        XCTAssertGreaterThanOrEqual(output.filter { $0 == 88 }.count, 32768)
    }

    func testPTYExitIsReapedAndReportsUnavailableExecutable() throws {
        let session = TerminalSession()
        defer { session.stop() }
        let ended = expectation(description: "failed exec exits and is reaped")
        var output = ""
        session.output = { output += String(decoding: $0, as: UTF8.self) }
        session.ended = { _ in ended.fulfill() }
        try session.start(shell: "/no-such-qnotch-shell", home: NSTemporaryDirectory(), columns: 80, rows: 18)
        wait(for: [ended], timeout: 8)
        XCTAssertTrue(session.reaped)
        XCTAssertTrue(output.contains("could not start"))
    }
}
