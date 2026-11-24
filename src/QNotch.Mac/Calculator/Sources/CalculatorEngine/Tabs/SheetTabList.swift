import Foundation

/// One sheet as the tab strip shows it.
struct SheetTab: Equatable { let id: UUID; let name: String; init(_ id: UUID, _ name: String) { self.id = id; self.name = name } }

/// A sheet the user closed whose delete is still waiting. Position is its place among the visible tabs when it was closed.
struct ClosedSheet: Equatable { let id: UUID, name: String, position: Int, wasActive: Bool }

enum CloseVerdict { case allowed, unknown, lastSheet }

/// The tab strip's state, without any UI: which sheets show, which is active, and which were closed but not deleted yet.
/// A closed sheet stays in the workspace catalog until its undo window ends, so a crash during the window loses nothing, its name stays
/// taken and it still counts toward the sheet limit. All closes share one deadline, moved on by every close and undo, so a run of closes
/// stays undoable one by one. Not thread safe: the UI thread owns it.
final class SheetTabList {
    /// Eight seconds, in ticks.
    static let undoWindow: Int64 = 8 * Ticks.perSecond
    static let maxSheets = 256

    private var all: [SheetTab] = []
    private var closedSheets: [ClosedSheet] = [] // oldest first
    private var closedIds = Set<UUID>()
    private var visibleCache: [SheetTab]?

    private(set) var activeId = UUID.netEmpty
    /// When the waiting closes become real deletes; nil while nothing waits.
    private(set) var dueAt: DateTimeOffset?

    var visible: [SheetTab] {
        if let visibleCache { return visibleCache }
        let tabs = all.filter { !closedIds.contains($0.id) }
        visibleCache = tabs
        return tabs
    }
    var closed: [ClosedSheet] { closedSheets }
    var lastClosed: ClosedSheet? { closedSheets.last }

    /// Every sheet the catalog still holds, waiting closes included. This is what the sheet limit counts.
    var totalCount: Int { all.count }
    var canCreate: Bool { all.count < SheetTabList.maxSheets }
    func isClosed(_ id: UUID) -> Bool { closedIds.contains(id) }
    func contains(_ id: UUID) -> Bool { all.contains { $0.id == id } }

    /// Takes the catalog's sheets and active sheet. A waiting close survives unless its sheet left the catalog.
    func update<S: Sequence>(_ catalog: S, _ activeId: UUID) where S.Element == SheetTab {
        all = Array(catalog)
        visibleCache = nil
        let present = Set(all.map(\.id))
        let before = closedSheets.count
        closedSheets.removeAll { !present.contains($0.id) }
        if closedSheets.count < before {
            closedIds.formIntersection(present)
            if closedSheets.isEmpty { dueAt = nil }
        }
        // Sync removed every other sheet while this one waited for its delete: it is now the last sheet, so it stays.
        if !closedSheets.isEmpty && visible.isEmpty {
            closedIds.remove(closedSheets.removeLast().id)
            visibleCache = nil
            if closedSheets.isEmpty { dueAt = nil }
        }
        self.activeId = activeId
        if closedIds.contains(self.activeId) || !present.contains(self.activeId) {
            self.activeId = visible.first?.id ?? activeId
        }
    }

    @discardableResult
    func setActive(_ id: UUID) -> Bool {
        if closedIds.contains(id) || !contains(id) { return false }
        activeId = id
        return true
    }

    func canClose(_ id: UUID) -> CloseVerdict {
        if closedIds.contains(id) || !contains(id) { return .unknown }
        return visible.count <= 1 ? .lastSheet : .allowed
    }

    /// The other visible sheets in the order a close should try them: outward from the sheet, right side first.
    func neighborsOf(_ id: UUID) -> [UUID] {
        let tabs = visible
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        var result: [UUID] = []
        for distance in stride(from: 1, to: tabs.count, by: 1) {
            if index + distance < tabs.count { result.append(tabs[index + distance].id) }
            if index - distance >= 0 { result.append(tabs[index - distance].id) }
        }
        return result
    }

    /// Hides a sheet and starts or extends the undo window. Closing the active sheet activates `next`, or its
    /// nearest neighbor when none is given. `wasActive` makes Undo bring the sheet back in front even though another
    /// sheet was activated just before the close. Nil when the sheet cannot be closed.
    @discardableResult
    func close(_ id: UUID, _ now: DateTimeOffset, next: UUID? = nil, wasActive: Bool = false) -> ClosedSheet? {
        if canClose(id) != .allowed { return nil }
        let active = id == activeId
        let successor = active ? next ?? neighborsOf(id)[0] : activeId
        if active && (successor == id || closedIds.contains(successor) || !contains(successor)) { return nil }
        let tabs = visible
        let position = tabs.firstIndex { $0.id == id } ?? 0
        let closed = ClosedSheet(id: id, name: tabs[position].name, position: position, wasActive: active || wasActive)
        closedSheets.append(closed)
        closedIds.insert(id)
        visibleCache = nil
        activeId = successor
        dueAt = now.addingTicks(SheetTabList.undoWindow)
        return closed
    }

    /// Brings back the most recent close at its old place, active again if it was active. Waiting closes get a fresh window.
    @discardableResult
    func undo(_ now: DateTimeOffset) -> ClosedSheet? {
        guard let sheet = closedSheets.popLast() else { return nil }
        closedIds.remove(sheet.id)
        visibleCache = nil
        if sheet.wasActive { activeId = sheet.id }
        dueAt = closedSheets.isEmpty ? nil : now.addingTicks(SheetTabList.undoWindow)
        return sheet
    }

    /// The closes whose window ended, oldest first. They leave this list; the caller deletes them from the store.
    func takeExpired(_ now: DateTimeOffset) -> [ClosedSheet] {
        if let due = dueAt, now >= due { return takeAll() }
        return []
    }

    /// Every waiting close, for shutdown.
    func takeAll() -> [ClosedSheet] {
        let taken = closedSheets
        closedSheets.removeAll()
        closedIds.removeAll()
        dueAt = nil
        if !taken.isEmpty {
            let gone = Set(taken.map(\.id))
            all.removeAll { gone.contains($0.id) }
            visibleCache = nil
        }
        return taken
    }

    /// The first numbered name no sheet uses, counting sheets that are waiting to be deleted.
    func uniqueName(_ format: (Int) -> String) -> String {
        let used = Set(all.map { OrdinalString($0.name) })
        var number = 1
        while true {
            let name = format(number)
            if !used.contains(OrdinalString(name)) { return name }
            number += 1
        }
    }
}
