import AppKit

/// A custom control that tells outlines its role (a selectable row, a tab, a radio-style choice) where
/// AppKit's class and accessibility role do not.
protocol OutlineRoleProviding: NSView {
    var outlineRole: Outline.Role? { get }
    /// Whether a `Toggle` is on, where the button's own state does not say (radio-style choices).
    var outlineChecked: Bool? { get }
}

extension OutlineRoleProviding {
    var outlineChecked: Bool? { nil }
}

/// The text outline of a view (spec/diagnostics.md, Outline format): the visible text and controls,
/// with their names, ids, values and states, nested by containment. What an agent reads instead of a PNG.
enum Outline {
    enum Role: String {
        case button = "Button", toggle = "Toggle", tab = "Tab", field = "Field", secureField = "SecureField"
        case slider = "Slider", progress = "Progress", popUp = "PopUp", item = "Item", link = "Link"
    }

    static func text(for root: NSView) -> String {
        root.layoutSubtreeIfNeeded()
        var lines: [String] = []
        walk(root, root: root, depth: 0, clip: root.bounds, titles: [], into: &lines)
        return lines.map { $0 + "\n" }.joined()
    }

    /// The interactive control lines of an outline without a name (accessible-names check).
    /// Progress is read-only and needs none.
    static func unnamedControls(in outline: String) -> [String] {
        outline.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), line[line.index(after: line.startIndex)..<close] != Role.progress.rawValue else { return false }
            return !line[close...].hasPrefix("] \"")
        }
    }

    /// Writes the outline of `view` beside the PNG at `url` (same name, `.txt`).
    static func write(view: NSView, png url: URL) throws {
        try Data(text(for: view).utf8).write(to: url.deletingPathExtension().appendingPathExtension("txt"))
    }

    private static func walk(_ view: NSView, root: NSView, depth: Int, clip: NSRect, titles: Set<String>, into lines: inout [String]) {
        guard !view.isHidden, view.alphaValue > 0.01, !(view is NSScroller), view.bounds.width > 0, view.bounds.height > 0 else { return }
        let frame = view.convert(view.bounds, to: root)
        guard frame.intersects(clip) else { return }
        // An illustration (one accessibility image) is not read for its parts.
        if view.isAccessibilityElement(), view.accessibilityRole() == .image { return }
        let clip = view is NSClipView ? clip.intersection(frame) : clip
        var depth = depth, titles = titles
        if let role = role(of: view) {
            let name = name(of: view)
            lines.append(String(repeating: "  ", count: depth) + control(view, role: role, name: name))
            guard [.button, .toggle, .tab, .item, .link].contains(role) else { return }
            depth += 1
            titles = Set([name, (view as? NSButton)?.title].compactMap { $0 })
        } else if let text = text(of: view) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !titles.contains(text), !titles.contains(trimmed) {
                lines.append(String(repeating: "  ", count: depth) + quote(text))
            }
            return
        }
        for child in view.subviews { walk(child, root: root, depth: depth, clip: clip, titles: titles, into: &lines) }
    }

    /// Static text: a label or a read-only text view.
    private static func text(of view: NSView) -> String? {
        if let field = view as? NSTextField, !field.isEditable { return field.stringValue }
        if let text = view as? NSTextView, !text.isEditable { return text.string }
        return nil
    }

    static func role(of view: NSView) -> Role? {
        if let provider = view as? OutlineRoleProviding, let role = provider.outlineRole { return role }
        switch view {
        case is NSSecureTextField: return .secureField
        case is NSComboBox, is NSPopUpButton: return .popUp
        case let field as NSTextField: return field.isEditable ? .field : nil
        case let text as NSTextView: return text.isEditable ? .field : nil
        case is NSSlider: return .slider
        case is NSProgressIndicator: return .progress
        case is NSSwitch: return .toggle
        case is NSTableRowView: return .item
        case let button as NSButton:
            if isLink(button) { return .link }
            let ax = button.accessibilityRole()
            if ax == .checkBox || ax == .radioButton || (button.cell as? NSButtonCell).map({ !$0.showsStateBy.isEmpty }) == true { return .toggle }
            return button.accessibilitySubrole() == tabButton ? .tab : .button
        default:
            guard view.isAccessibilityElement() else { return nil }
            if view.accessibilitySubrole() == tabButton { return .tab }
            switch view.accessibilityRole() {
            case .button?: return .button
            case .checkBox?, .radioButton?: return .toggle
            case .slider?: return .slider
            case .progressIndicator?, .levelIndicator?: return .progress
            case .popUpButton?, .comboBox?: return .popUp
            case .row?: return .item
            case .link?: return .link
            case .textField?, .textArea?: return .field
            default: return nil
            }
        }
    }

    private static let tabButton = NSAccessibility.Subrole(rawValue: "AXTabButton")

    private static func isLink(_ button: NSButton) -> Bool {
        if button.accessibilityRole() == .link { return true }
        let title = button.attributedTitle
        return title.length > 0 && title.attribute(.link, at: 0, effectiveRange: nil) != nil
    }

    /// The accessible name, else the visible title (or a field's placeholder), else the tooltip.
    static func name(of view: NSView) -> String? {
        var candidates: [String?] = [view.accessibilityLabel()]
        if let button = view as? NSButton, !(button is NSPopUpButton) { candidates += [button.title, button.image?.accessibilityDescription] }
        if let field = view as? NSTextField { candidates += [field.placeholderString, field.placeholderAttributedString?.string] }
        candidates.append(view.toolTip)
        return candidates.lazy.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A stable kebab-case identifier; AppKit's own ("_NS:…") are left out.
    static func id(of view: NSView) -> String? {
        [view.identifier?.rawValue, view.accessibilityIdentifier()].lazy.compactMap { $0 }.first { id in
            id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
        }
    }

    private static func control(_ view: NSView, role: Role, name: String?) -> String {
        var parts = ["[\(role.rawValue)]"]
        if let name { parts.append(quote(name)) }
        if let id = id(of: view) { parts.append("#" + id) }
        if let value = value(of: view, role: role) { parts.append(value) }
        if role == .toggle, checked(view) { parts.append("checked") }
        if selected(view) { parts.append("selected") }
        if focused(view) { parts.append("focused") }
        if let control = view as? NSControl, !control.isEnabled { parts.append("disabled") }
        return parts.joined(separator: " ")
    }

    private static func value(of view: NSView, role: Role) -> String? {
        switch (role, view) {
        case (.slider, let slider as NSSlider): return range(slider.doubleValue, of: slider.maxValue)
        case (.slider, let slider as LevelSlider): return range(slider.value, of: slider.maxValue)
        case (.progress, let progress as NSProgressIndicator): return progress.isIndeterminate ? nil : range(progress.doubleValue, of: progress.maxValue)
        case (.slider, _), (.progress, _):
            if let value = view.accessibilityValue() as? NSNumber, let max = view.accessibilityMaxValue() as? NSNumber { return range(value.doubleValue, of: max.doubleValue) }
            // "40%" or "40 percent used".
            guard let text = view.accessibilityValue() as? String, text.contains("%") || text.contains("percent"),
                  let number = Double(text.prefix { $0.isNumber || $0 == "." }) else { return nil }
            return range(number, of: 100)
        case (.popUp, let popUp as NSPopUpButton): return "value=" + quote(popUp.titleOfSelectedItem ?? "")
        case (.popUp, let field as NSTextField), (.field, let field as NSTextField): return "value=" + quote(field.stringValue)
        case (.field, let text as NSTextView): return "value=" + quote(text.string)
        case (.field, _), (.popUp, _): return "value=" + quote(view.accessibilityValue() as? String ?? "")
        default: return nil
        }
    }

    private static func range(_ value: Double, of max: Double) -> String { "\(number(value)) of \(number(max))" }

    /// Up to two decimals, no trailing zeros; never negative (the grammar has no sign).
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.2f", Swift.max(0, value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func checked(_ view: NSView) -> Bool {
        if let provider = view as? OutlineRoleProviding, let checked = provider.outlineChecked { return checked }
        if let button = view as? NSButton { return button.state == .on }
        if let toggle = view as? NSSwitch { return toggle.state == .on }
        return (view.accessibilityValue() as? NSNumber)?.intValue == 1
    }

    private static func selected(_ view: NSView) -> Bool {
        (view as? NSTableRowView)?.isSelected == true || view.isAccessibilitySelected()
    }

    static func focused(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder else { return false }
        if responder === view { return true }
        // A text field edits through the window's field editor, whose delegate is the field.
        return view is NSTextField && (responder as? NSTextView)?.delegate === view
    }

    /// Quoted, with `\`, `"`, line breaks and tabs escaped.
    static func quote(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\t": out += "\\t"
            case _ where character.isNewline: out += "\\n"
            default: out.append(character)
            }
        }
        return out + "\""
    }
}
