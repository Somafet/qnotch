import Foundation

/// One sheet as the tab strip shows it (C# SheetTab).
struct CalculatorTab: Equatable {
    let id: UUID
    let name: String
}

/// A sheet the user closed whose delete is still waiting (C# ClosedSheet). `position` is its place among
/// the visible tabs when it was closed.
struct CalculatorClosedSheet: Equatable {
    let id: UUID
    let name: String
    let position: Int
    let wasActive: Bool
}

enum CalculatorCloseVerdict { case allowed, unknown, lastSheet }

/// The tab strip's state without any UI (Windows `QNotch.Calculator.SheetTabList`, docs/windows/calculator.md, Tabs):
/// which sheets show, which is active, and which were closed but not deleted yet. A closed sheet stays in the
/// documents until its undo window ends, keeps its name and counts toward the sheet limit. All waiting closes
/// share one deadline, moved on by every close and undo. Main thread only.
///
/// The documents port supplies the real list; until then `CalculatorTabList` below implements it.
protocol CalculatorTabState: AnyObject {
    var activeID: UUID { get }
    /// When the waiting closes become real deletes; nil while nothing waits.
    var dueAt: Date? { get }
    var visible: [CalculatorTab] { get }
    /// Oldest first.
    var closed: [CalculatorClosedSheet] { get }
    var lastClosed: CalculatorClosedSheet? { get }
    /// Every sheet the documents still hold, waiting closes included: what the sheet limit counts.
    var totalCount: Int { get }
    var canCreate: Bool { get }
    func isClosed(_ id: UUID) -> Bool
    func contains(_ id: UUID) -> Bool
    /// Takes the catalog's sheets and active sheet. A waiting close survives unless its sheet left the catalog.
    func update(_ catalog: [CalculatorTab], active: UUID)
    @discardableResult func setActive(_ id: UUID) -> Bool
    func canClose(_ id: UUID) -> CalculatorCloseVerdict
    /// The other visible sheets in the order a close tries them: outward from the sheet, right side first.
    func neighbors(of id: UUID) -> [UUID]
    /// Hides a sheet and starts or extends the undo window. Closing the active sheet activates `next`, or its
    /// nearest neighbor. `wasActive` makes Undo bring it back in front although another sheet was activated
    /// just before the close. Nil when the sheet cannot be closed.
    @discardableResult func close(_ id: UUID, now: Date, next: UUID?, wasActive: Bool) -> CalculatorClosedSheet?
    /// Brings back the most recent close at its old place, active again if it was active.
    @discardableResult func undo(now: Date) -> CalculatorClosedSheet?
    /// The closes whose window ended, oldest first; they leave the list and the caller deletes them.
    func takeExpired(now: Date) -> [CalculatorClosedSheet]
    /// Every waiting close, for shutdown.
    func takeAll() -> [CalculatorClosedSheet]
    /// The first numbered name no sheet uses, counting sheets waiting to be deleted.
    func uniqueName(_ format: (Int) -> String) -> String
}

extension CalculatorTabState {
    @discardableResult func close(_ id: UUID, now: Date) -> CalculatorClosedSheet? { close(id, now: now, next: nil, wasActive: false) }
}

/// A line-for-line port of the C# SheetTabList, used until the documents port provides its own.
final class CalculatorTabList: CalculatorTabState {
    static let undoWindow: TimeInterval = 8
    static let maxSheets = 256

    private var all: [CalculatorTab] = []
    private var closedSheets: [CalculatorClosedSheet] = []
    private var closedIDs: Set<UUID> = []
    private var cachedVisible: [CalculatorTab]?
    private(set) var activeID = UUID()
    private(set) var dueAt: Date?

    var visible: [CalculatorTab] {
        if let cachedVisible { return cachedVisible }
        let tabs = all.filter { !closedIDs.contains($0.id) }
        cachedVisible = tabs
        return tabs
    }
    var closed: [CalculatorClosedSheet] { closedSheets }
    var lastClosed: CalculatorClosedSheet? { closedSheets.last }
    var totalCount: Int { all.count }
    var canCreate: Bool { all.count < Self.maxSheets }
    func isClosed(_ id: UUID) -> Bool { closedIDs.contains(id) }
    func contains(_ id: UUID) -> Bool { all.contains { $0.id == id } }

    func update(_ catalog: [CalculatorTab], active: UUID) {
        all = catalog
        cachedVisible = nil
        let present = Set(all.map(\.id))
        let before = closedSheets.count
        closedSheets.removeAll { !present.contains($0.id) }
        if closedSheets.count != before {
            closedIDs.formIntersection(present)
            if closedSheets.isEmpty { dueAt = nil }
        }
        // Sync removed every other sheet while this one waited for its delete: it is now the last sheet, so it stays.
        if !closedSheets.isEmpty, visible.isEmpty, let last = closedSheets.popLast() {
            closedIDs.remove(last.id)
            cachedVisible = nil
            if closedSheets.isEmpty { dueAt = nil }
        }
        activeID = active
        if closedIDs.contains(activeID) || !present.contains(activeID) { activeID = visible.first?.id ?? active }
    }

    @discardableResult
    func setActive(_ id: UUID) -> Bool {
        guard !closedIDs.contains(id), contains(id) else { return false }
        activeID = id
        return true
    }

    func canClose(_ id: UUID) -> CalculatorCloseVerdict {
        if closedIDs.contains(id) || !contains(id) { return .unknown }
        return visible.count <= 1 ? .lastSheet : .allowed
    }

    func neighbors(of id: UUID) -> [UUID] {
        let tabs = visible
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        var result: [UUID] = []
        for distance in 1..<max(1, tabs.count) {
            if index + distance < tabs.count { result.append(tabs[index + distance].id) }
            if index - distance >= 0 { result.append(tabs[index - distance].id) }
        }
        return result
    }

    @discardableResult
    func close(_ id: UUID, now: Date, next: UUID?, wasActive: Bool) -> CalculatorClosedSheet? {
        guard canClose(id) == .allowed else { return nil }
        let active = id == activeID
        guard let successor = active ? next ?? neighbors(of: id).first : activeID else { return nil }
        if active, successor == id || closedIDs.contains(successor) || !contains(successor) { return nil }
        let tabs = visible
        let position = tabs.firstIndex { $0.id == id } ?? 0
        let sheet = CalculatorClosedSheet(id: id, name: tabs[position].name, position: position, wasActive: active || wasActive)
        closedSheets.append(sheet)
        closedIDs.insert(id)
        cachedVisible = nil
        activeID = successor
        dueAt = now.addingTimeInterval(Self.undoWindow)
        return sheet
    }

    @discardableResult
    func undo(now: Date) -> CalculatorClosedSheet? {
        guard let sheet = closedSheets.popLast() else { return nil }
        closedIDs.remove(sheet.id)
        cachedVisible = nil
        if sheet.wasActive { activeID = sheet.id }
        dueAt = closedSheets.isEmpty ? nil : now.addingTimeInterval(Self.undoWindow)
        return sheet
    }

    func takeExpired(now: Date) -> [CalculatorClosedSheet] {
        guard let dueAt, now >= dueAt else { return [] }
        return takeAll()
    }

    func takeAll() -> [CalculatorClosedSheet] {
        let taken = closedSheets
        closedSheets.removeAll()
        closedIDs.removeAll()
        dueAt = nil
        if !taken.isEmpty {
            let gone = Set(taken.map(\.id))
            all.removeAll { gone.contains($0.id) }
            cachedVisible = nil
        }
        return taken
    }

    func uniqueName(_ format: (Int) -> String) -> String {
        let used = Set(all.map(\.name))
        var number = 1
        while used.contains(format(number)) { number += 1 }
        return format(number)
    }
}
