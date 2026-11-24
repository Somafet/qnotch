import Foundation
import CalculatorEngine

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
/// `CalculatorTabList` below implements it over the engine's SheetTabList.
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

/// The engine's SheetTabList (CalculatorSheetTabs) behind the app's tab state.
final class CalculatorTabList: CalculatorTabState {
    static let undoWindow: TimeInterval = CalculatorSheetTabs.undoWindow
    static let maxSheets = CalculatorSheetTabs.maxSheets

    private let list = CalculatorSheetTabs()
    private var cachedVisible: [CalculatorTab]?

    var activeID: UUID { list.activeID }
    var dueAt: Date? { list.dueAt }
    var visible: [CalculatorTab] {
        if let cachedVisible { return cachedVisible }
        let tabs = list.visible.map { CalculatorTab(id: $0.id, name: $0.name) }
        cachedVisible = tabs
        return tabs
    }
    var closed: [CalculatorClosedSheet] { list.closed.map(Self.closed) }
    var lastClosed: CalculatorClosedSheet? { list.lastClosed.map(Self.closed) }
    var totalCount: Int { list.totalCount }
    var canCreate: Bool { list.canCreate }
    func isClosed(_ id: UUID) -> Bool { list.isClosed(id) }
    func contains(_ id: UUID) -> Bool { list.contains(id) }

    private static func closed(_ sheet: CalculatorSheetTabs.Closed) -> CalculatorClosedSheet {
        CalculatorClosedSheet(id: sheet.id, name: sheet.name, position: sheet.position, wasActive: sheet.wasActive)
    }
    private func changed<T>(_ value: T) -> T { cachedVisible = nil; return value }

    func update(_ catalog: [CalculatorTab], active: UUID) {
        list.update(catalog.map { CalculatorSheetTabs.Tab(id: $0.id, name: $0.name) }, active: active)
        cachedVisible = nil
    }
    @discardableResult func setActive(_ id: UUID) -> Bool { list.setActive(id) }
    func canClose(_ id: UUID) -> CalculatorCloseVerdict {
        switch list.canClose(id) { case .allowed: .allowed; case .unknown: .unknown; case .lastSheet: .lastSheet }
    }
    func neighbors(of id: UUID) -> [UUID] { list.neighbors(of: id) }
    @discardableResult
    func close(_ id: UUID, now: Date, next: UUID?, wasActive: Bool) -> CalculatorClosedSheet? {
        changed(list.close(id, now: now, next: next, wasActive: wasActive).map(Self.closed))
    }
    @discardableResult func undo(now: Date) -> CalculatorClosedSheet? { changed(list.undo(now: now).map(Self.closed)) }
    func takeExpired(now: Date) -> [CalculatorClosedSheet] { changed(list.takeExpired(now: now).map(Self.closed)) }
    func takeAll() -> [CalculatorClosedSheet] { changed(list.takeAll().map(Self.closed)) }
    func uniqueName(_ format: (Int) -> String) -> String { list.uniqueName(format) }
}
