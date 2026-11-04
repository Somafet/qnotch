import XCTest
import AppKit
@testable import QNotchMac

final class DropScreenTests: XCTestCase {
    private let zip = URL(fileURLWithPath: "/tmp/demo/holiday-photos.zip", isDirectory: false)
    private let pdf = URL(fileURLWithPath: "/tmp/demo/trip-notes.pdf", isDirectory: false)

    private func source(_ id: String, order: Int, _ targets: @escaping ([URL]) -> [DropTarget]) -> DropSource {
        DropSource(id: id, title: id.capitalized, glyph: "tray", order: order, targets: targets)
    }

    // MARK: Registry

    func testDropSourcesAreOrderedAndRemovedWithTheirModule() {
        let registries = ModuleRegistries()
        registries.owner = "taildrop"
        registries.dropSources.register(source("taildrop", order: 20) { _ in [] })
        registries.owner = "filetray"
        registries.dropSources.register(source("files", order: 10) { _ in [] })
        registries.owner = nil
        XCTAssertEqual(registries.dropSources.items.map(\.id), ["files", "taildrop"])
        XCTAssertEqual(registries.dropSources.owner(of: "files"), "filetray")
        registries.removeAll(owner: "filetray")
        XCTAssertEqual(registries.dropSources.items.map(\.id), ["taildrop"], "A module turned off registers nothing")
        registries.removeAll()
        XCTAssertTrue(registries.dropSources.items.isEmpty)
    }

    // MARK: Model

    func testModelHeaderGroupsAndTileNames() {
        var dropped: [URL] = []
        let sources = [
            source("taildrop", order: 20) { _ in [DropTarget(id: "n1", title: "pixel-8", subtitle: "Android", glyph: "smartphone") { dropped += $0 }] },
            source("empty", order: 15) { _ in [] },
            source("files", order: 10) { files in [DropTarget(id: "add", title: "Add to tray", glyph: "tray", enabled: files.count > 1) { _ in }] }
        ]
        let made = DropScreenModel.make(files: [zip, pdf], sources: sources)
        XCTAssertEqual(made.model.header, "Drop 2 items")
        XCTAssertEqual(made.model.groups.map(\.id), ["files", "taildrop"], "In order; a source without targets is left out")
        let tile = made.model.groups[1].tiles[0]
        XCTAssertEqual(tile.identifier, "drop-taildrop-n1")
        XCTAssertEqual(tile.label, "pixel-8, Taildrop")
        XCTAssertEqual(made.model.groups[0].tiles[0].enabled, true)
        made.actions["drop-taildrop-n1"]?([zip])
        XCTAssertEqual(dropped, [zip])

        XCTAssertEqual(DropScreenModel.header(for: [zip]), "Drop holiday-photos.zip")
        XCTAssertTrue(DropScreenModel.make(files: [zip], sources: [sources[1]]).model.isEmpty)
    }

    func testScreenRebuildsOnlyWhenTheModelChanges() {
        var online = true
        let sources = [source("taildrop", order: 20) { _ in
            [DropTarget(id: "n1", title: "pixel-8", subtitle: online ? "Android" : "Offline", glyph: "smartphone", enabled: online) { _ in }]
        }]
        let screen = DropScreenView()
        screen.frame = NSRect(x: 0, y: 0, width: 676, height: 364)
        let first = DropScreenModel.make(files: [zip], sources: sources)
        XCTAssertTrue(screen.apply(first.model, actions: first.actions))
        let tile = screen.tiles.first
        XCTAssertFalse(screen.apply(DropScreenModel.make(files: [zip], sources: sources).model, actions: first.actions), "Same model: nothing rebuilt")
        XCTAssertTrue(screen.tiles.first === tile)
        online = false
        let offline = DropScreenModel.make(files: [zip], sources: sources)
        XCTAssertTrue(screen.apply(offline.model, actions: offline.actions))
        XCTAssertFalse(screen.tiles.first === tile)
        XCTAssertEqual(screen.tiles.first?.isEnabled, false)
        XCTAssertEqual(screen.tiles.first?.isAccessibilityEnabled(), false)
        XCTAssertNil(screen.tiles.first.flatMap(screen.action(for:)), "A disabled tile refuses the drop")
    }

    func testHoverHighlightsOnlyEnabledTiles() {
        let sources = [source("files", order: 10) { _ in
            [DropTarget(id: "on", title: "On", glyph: "tray") { _ in }, DropTarget(id: "off", title: "Off", subtitle: "No", glyph: "tray", enabled: false) { _ in }]
        }]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 676, height: 364), styleMask: [.borderless], backing: .buffered, defer: true)
        let screen = DropScreenView()
        window.contentView = screen
        let made = DropScreenModel.make(files: [zip], sources: sources)
        screen.apply(made.model, actions: made.actions)
        screen.layoutSubtreeIfNeeded()
        func center(_ tile: DropTile) -> NSPoint { tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil) }
        let on = screen.tiles[0], off = screen.tiles[1]
        XCTAssertEqual(screen.hover(at: center(on)), .copy)
        XCTAssertTrue(on.dropping)
        XCTAssertEqual(screen.hover(at: center(off)), [], "A disabled tile refuses")
        XCTAssertFalse(on.dropping)
        XCTAssertFalse(off.dropping)
        XCTAssertEqual(screen.hover(at: NSPoint(x: 2, y: 2)), [], "Outside every tile is refused")
        XCTAssertTrue(screen.tile(at: center(off)) === off)
    }

    // MARK: File tray

    func testFileTrayTargetIsDisabledWhenEverythingIsAlreadyInTheTray() {
        var added: [URL] = []
        let fresh = FileTrayModule.dropTarget(files: [zip, pdf], trayPaths: [zip.path]) { added = $0 }
        XCTAssertEqual(fresh.id, "add")
        XCTAssertEqual(fresh.title, "Add to tray")
        XCTAssertEqual(fresh.subtitle, "Keep them within reach")
        XCTAssertTrue(fresh.enabled)
        fresh.drop([pdf])
        XCTAssertEqual(added, [pdf])
        let known = FileTrayModule.dropTarget(files: [zip, pdf], trayPaths: [zip.path, pdf.path]) { _ in }
        XCTAssertFalse(known.enabled)
        XCTAssertEqual(known.subtitle, "Already in the tray")
    }
}
