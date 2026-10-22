import Foundation

/// A bounded VT100-style screen for quick commands. Unknown controls are consumed, never
/// interpreted as commands, URLs, clipboard writes or file operations. No xterm claim.
struct TerminalScreen {
    struct Style: Equatable {
        var foreground = -1, background = -1
        var bold = false, inverse = false
    }
    struct Cell: Equatable {
        var text = " "
        var style = Style()
        var continuation = false
    }
    private(set) var columns: Int
    private(set) var rows: Int
    private(set) var grid: [[Cell]]
    private(set) var history: [[Cell]] = []
    private(set) var x = 0, y = 0
    private(set) var cursorVisible = true
    private(set) var applicationCursor = false
    private(set) var bracketedPaste = false
    private var style = Style()
    private var saved = (0, 0)
    private var top = 0, bottom: Int
    private var wrapPending = false, autoWrap = true, origin = false
    private var primary: ([[Cell]], Int, Int)?
    private enum State { case text, escape, charset, csi, string, stringEscape }
    private var state = State.text
    private var sequence = [UInt8]()
    private var utf8 = [UInt8]()
    private var sequenceOverflow = false
    var reply: ((Data) -> Void)?

    init(columns: Int = 80, rows: Int = 18) {
        self.columns = min(240, max(20, columns)); self.rows = min(100, max(4, rows))
        bottom = self.rows - 1
        grid = Array(repeating: Array(repeating: Cell(), count: self.columns), count: self.rows)
    }

    mutating func resize(columns: Int, rows: Int) {
        let c = min(240, max(20, columns)), r = min(100, max(4, rows))
        guard c != self.columns || r != self.rows else { return }
        func fit(_ lines: [[Cell]]) -> [[Cell]] {
            (0..<r).map { row in
                let old = row < lines.count ? Array(lines[row].prefix(c)) : []
                return old + Array(repeating: Cell(), count: max(0, c - old.count))
            }
        }
        grid = fit(grid)
        if let old = primary { primary = (fit(old.0), min(old.1, c - 1), min(old.2, r - 1)) }
        self.columns = c; self.rows = r
        x = min(x, c - 1); y = min(y, r - 1); top = 0; bottom = r - 1; wrapPending = false
    }

    var lines: [[Cell]] { (primary == nil ? history : []) + grid }
    var plainText: String { lines.map { Self.text($0) }.joined(separator: "\n") }
    static func text(_ cells: [Cell]) -> String {
        cells.filter { !$0.continuation }.map(\.text).joined().replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
    }

    mutating func feed(_ data: Data) { for byte in data { consume(byte) } }

    private mutating func consume(_ b: UInt8) {
        switch state {
        case .string:
            if b == 7 { state = .text } else if b == 27 { state = .stringEscape }
        case .stringEscape: state = b == 92 ? .text : .string
        case .charset: state = .text // ASCII only; DEC line drawing is a documented limit.
        case .escape:
            state = .text
            switch b {
            case 91: state = .csi; sequence.removeAll(keepingCapacity: true); sequenceOverflow = false
            case 93, 80, 94, 95: state = .string
            case 40, 41: state = .charset
            case 55: saved = (x, y)
            case 56: (x, y) = saved; clamp()
            case 68: lineFeed()
            case 69: x = 0; lineFeed()
            case 77: if y == top { scrollDown() } else { y = max(0, y - 1) }
            case 99:
                let send = reply
                self = TerminalScreen(columns: columns, rows: rows)
                reply = send
            default: break
            }
        case .csi:
            if b == 27 { state = .escape; return }
            if (0x40...0x7E).contains(b) {
                if !sequenceOverflow { executeCSI(b) }
                state = .text
            } else if sequence.count < 128 { sequence.append(b) } else { sequenceOverflow = true }
        case .text:
            if b < 32 || b == 127 {
                if !utf8.isEmpty { printScalar("�"); utf8.removeAll(keepingCapacity: true) }
                switch b {
                case 27: state = .escape
                case 13: x = 0; wrapPending = false
                case 10, 11, 12: lineFeed()
                case 8: x = max(0, x - 1); wrapPending = false
                case 9: x = min(columns - 1, (x / 8 + 1) * 8); wrapPending = false
                default: break
                }
                return
            }
            if b < 128 {
                if !utf8.isEmpty { printScalar("�"); utf8.removeAll(keepingCapacity: true) }
                printScalar(UnicodeScalar(b))
            } else {
                if !utf8.isEmpty, !(0x80...0xBF).contains(b) { printScalar("�"); utf8.removeAll(keepingCapacity: true) }
                utf8.append(b)
                let needed = utf8[0] < 0xE0 ? 2 : utf8[0] < 0xF0 ? 3 : 4
                if utf8.count >= needed {
                    for scalar in String(decoding: utf8, as: UTF8.self).unicodeScalars { printScalar(scalar) }
                    utf8.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    private mutating func printScalar(_ scalar: UnicodeScalar) {
        let v = scalar.value
        if scalar.properties.generalCategory == .nonspacingMark || scalar.properties.generalCategory == .enclosingMark {
            let previous = wrapPending ? x : max(0, x - 1)
            if grid[y][previous].text.unicodeScalars.count < 8 { grid[y][previous].text.unicodeScalars.append(scalar) }
            return
        }
        // Common East Asian and emoji widths. ZWJ/variation-selector shaping is not emulated.
        let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE10...0xFE6F).contains(v) || (0xFF01...0xFF60).contains(v)
            || (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFF).contains(v)
        let width = wide ? 2 : 1
        if autoWrap && (wrapPending || x + width > columns) { x = 0; lineFeed() }
        wrapPending = false
        // Clear either half of a wide glyph being overwritten.
        if grid[y][x].continuation, x > 0 { grid[y][x - 1] = Cell() }
        if x + 1 < columns, grid[y][x + 1].continuation { grid[y][x + 1] = Cell() }
        grid[y][x] = Cell(text: String(scalar), style: style)
        if width == 2, x + 1 < columns { grid[y][x + 1] = Cell(text: "", style: style, continuation: true) }
        if x + width >= columns { x = columns - 1; wrapPending = autoWrap } else { x += width }
    }

    private mutating func clamp() { x = min(columns - 1, max(0, x)); y = min(rows - 1, max(0, y)); wrapPending = false }
    private var blank: [Cell] { Array(repeating: Cell(style: style), count: columns) }
    private mutating func lineFeed() {
        wrapPending = false
        if y == bottom { scrollUp() } else { y = min(rows - 1, y + 1) }
    }
    private mutating func scrollUp() {
        let removed = grid.remove(at: top)
        grid.insert(blank, at: bottom)
        if top == 0, bottom == rows - 1, primary == nil {
            history.append(removed)
            if history.count > 500 { history.removeFirst(history.count - 500) }
        }
    }
    private mutating func scrollDown() { grid.remove(at: bottom); grid.insert(blank, at: top) }

    private mutating func executeCSI(_ command: UInt8) {
        let string = String(decoding: sequence, as: UTF8.self)
        let privateMode = string.hasPrefix("?")
        let params = (privateMode ? String(string.dropFirst()) : string).split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func value(_ index: Int, _ fallback: Int = 1) -> Int { index < params.count && params[index] > 0 ? min(10_000, params[index]) : fallback }
        let n = value(0), first = params.first ?? 0
        let oldWrap = wrapPending
        switch command {
        case 65: y = max(origin ? top : 0, y - n)
        case 66: y = min(origin ? bottom : rows - 1, y + n)
        case 67: x = min(columns - 1, x + n)
        case 68: x = max(0, x - n)
        case 69: y = min(rows - 1, y + n); x = 0
        case 70: y = max(0, y - n); x = 0
        case 71: x = min(columns - 1, n - 1)
        case 100: y = min(rows - 1, n - 1 + (origin ? top : 0))
        case 72, 102: y = min(origin ? bottom : rows - 1, n - 1 + (origin ? top : 0)); x = min(columns - 1, value(1) - 1)
        case 74:
            if first == 2 { grid = Array(repeating: blank, count: rows) }
            else if first == 3 { history.removeAll() }
            else if first == 0 {
                erase(from: x, through: columns - 1, row: y)
                if y + 1 < rows { for row in (y + 1)..<rows { grid[row] = blank } }
            } else if first == 1 {
                erase(from: 0, through: x, row: y)
                for row in 0..<y { grid[row] = blank }
            }
        case 75:
            erase(from: first == 0 ? x : 0, through: first == 1 ? x : columns - 1, row: y)
        case 88: erase(from: x, through: min(columns - 1, x + n - 1), row: y)
        case 80:
            let count = min(n, columns - x)
            grid[y].removeSubrange(x..<(x + count)); grid[y] += Array(blank.prefix(count))
        case 64:
            grid[y].insert(contentsOf: blank.prefix(min(n, columns - x)), at: x); grid[y] = Array(grid[y].prefix(columns))
        case 76, 77:
            if (top...bottom).contains(y) {
                for _ in 0..<min(n, bottom - y + 1) {
                    if command == 76 { grid.remove(at: bottom); grid.insert(blank, at: y) }
                    else { grid.remove(at: y); grid.insert(blank, at: bottom) }
                }
            }
        case 83: for _ in 0..<min(n, rows) { scrollUp() }
        case 84: for _ in 0..<min(n, rows) { scrollDown() }
        case 114:
            let start = n - 1, end = value(1, rows) - 1
            if start < end, end < rows { top = start; bottom = end; x = 0; y = origin ? top : 0 }
        case 115: saved = (x, y)
        case 117: (x, y) = saved
        case 109: setStyle(params)
        case 104, 108:
            if privateMode {
                let enabled = command == 104
                for mode in params {
                    switch mode {
                    case 1: applicationCursor = enabled
                    case 6: origin = enabled; x = 0; y = enabled ? top : 0
                    case 7: autoWrap = enabled
                    case 25: cursorVisible = enabled
                    case 2004: bracketedPaste = enabled
                    case 1049:
                        if enabled, primary == nil { primary = (grid, x, y); grid = Array(repeating: blank, count: rows); x = 0; y = 0 }
                        else if !enabled, let old = primary { grid = old.0; x = old.1; y = old.2; primary = nil }
                    default: break
                    }
                }
            }
        case 110:
            if first == 6 { reply?(Data("\u{1B}[\(y + 1);\(x + 1)R".utf8)) }
            else if first == 5 { reply?(Data("\u{1B}[0n".utf8)) }
        case 99: reply?(Data("\u{1B}[?1;0c".utf8))
        default: break
        }
        clamp()
        if command == 109 || command == 110 || command == 99 { wrapPending = oldWrap }
    }

    private mutating func erase(from: Int, through: Int, row: Int) {
        guard from <= through else { return }
        for col in from...through { grid[row][col] = Cell(style: style) }
    }
    private mutating func setStyle(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0: style = Style()
            case 1: style.bold = true
            case 22: style.bold = false
            case 7: style.inverse = true
            case 27: style.inverse = false
            case 30...37: style.foreground = p - 30
            case 40...47: style.background = p - 40
            case 90...97: style.foreground = p - 90 + 8
            case 100...107: style.background = p - 100 + 8
            case 39: style.foreground = -1
            case 49: style.background = -1
            case 38, 48:
                if i + 2 < params.count, params[i + 1] == 5 {
                    if p == 38 { style.foreground = min(255, max(0, params[i + 2])) } else { style.background = min(255, max(0, params[i + 2])) }
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 { i += 4 } // Consume unsupported truecolor atomically.
            default: break
            }
            i += 1
        }
    }
}
