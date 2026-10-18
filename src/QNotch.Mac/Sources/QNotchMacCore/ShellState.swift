import Foundation

public struct ShellState {
    public enum Presentation: Equatable { case collapsed, hover, keyboard }
    public private(set) var presentation: Presentation = .collapsed
    public init() {}
    public var expanded: Bool { presentation != .collapsed }
    public var acceptsKeyboard: Bool { presentation == .keyboard }
    public mutating func open(keyboard: Bool) {
        if keyboard || presentation != .keyboard { presentation = keyboard ? .keyboard : .hover }
    }
    public mutating func pointerLeft() {
        if presentation == .hover { presentation = .collapsed }
    }
    public mutating func close() { presentation = .collapsed }
    /// Keeps the panel open without the keyboard (a pinned panel losing focus).
    public mutating func releaseKeyboard() {
        if presentation == .keyboard { presentation = .hover }
    }
}
