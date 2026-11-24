import Foundation

/// The sheet tab strip's state without any UI (C# SheetTabList, docs/windows/calculator.md, Tabs): which sheets show, which is active,
/// and which were closed but are not deleted yet. A closed sheet stays in the catalog until its undo window ends, keeps its name and counts
/// toward the sheet limit; every close and undo moves the one shared deadline. Main thread only.
public final class CalculatorSheetTabs {
    public struct Tab: Hashable, Sendable {
        public let id: UUID
        public let name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    /// A closed sheet waiting for its delete. `position` is its place among the visible tabs when it was closed.
    public struct Closed: Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let position: Int
        public let wasActive: Bool
        init(_ sheet: ClosedSheet) { id = sheet.id; name = sheet.name; position = sheet.position; wasActive = sheet.wasActive }
    }
    public enum Verdict: Sendable { case allowed, unknown, lastSheet }

    public static let undoWindow: TimeInterval = Double(SheetTabList.undoWindow) / Double(Ticks.perSecond)
    public static let maxSheets = SheetTabList.maxSheets

    private let list = SheetTabList()
    public init() {}

    public var activeID: UUID { list.activeId }
    public var dueAt: Date? { list.dueAt?.foundationDate }
    public var visible: [Tab] { list.visible.map { Tab(id: $0.id, name: $0.name) } }
    /// Oldest first.
    public var closed: [Closed] { list.closed.map(Closed.init) }
    public var lastClosed: Closed? { list.lastClosed.map(Closed.init) }
    public var totalCount: Int { list.totalCount }
    public var canCreate: Bool { list.canCreate }
    public func isClosed(_ id: UUID) -> Bool { list.isClosed(id) }
    public func contains(_ id: UUID) -> Bool { list.contains(id) }

    public func update(_ catalog: [Tab], active: UUID) { list.update(catalog.map { SheetTab($0.id, $0.name) }, active) }
    @discardableResult public func setActive(_ id: UUID) -> Bool { list.setActive(id) }
    public func canClose(_ id: UUID) -> Verdict {
        switch list.canClose(id) { case .allowed: .allowed; case .unknown: .unknown; case .lastSheet: .lastSheet }
    }
    public func neighbors(of id: UUID) -> [UUID] { list.neighborsOf(id) }
    @discardableResult
    public func close(_ id: UUID, now: Date, next: UUID? = nil, wasActive: Bool = false) -> Closed? {
        list.close(id, DateTimeOffset(now), next: next, wasActive: wasActive).map(Closed.init)
    }
    @discardableResult public func undo(now: Date) -> Closed? { list.undo(DateTimeOffset(now)).map(Closed.init) }
    public func takeExpired(now: Date) -> [Closed] { list.takeExpired(DateTimeOffset(now)).map(Closed.init) }
    public func takeAll() -> [Closed] { list.takeAll().map(Closed.init) }
    public func uniqueName(_ format: (Int) -> String) -> String { list.uniqueName(format) }
}
