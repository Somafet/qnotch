import AppKit
import QNotchMacCore

/// drop-screen: a file drag over the open panel shows the drop screen in place of the tabs, with
/// named File tray and Taildrop tiles; a disabled tile and the space between tiles refuse the
/// drop and close the screen; a drop on Add to tray adds the file and opens the Files tab.
/// Driven through the shell's drag entry points (the surface's NSDraggingDestination calls the
/// same ones); no pointer is moved and nothing is sent.
enum DropScreenSmoke {
    static func check(_ run: SnapshotRun) throws {
        let shell = run.shell
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NativeSmokeTest.Failure("drop-screen", message) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let tray = shell.module(FileTrayModule.self) else { return run.skip("drop-screen", "File tray is off") }
        try require(shell.surface.registeredDraggedTypes.contains(.fileURL), "The notch does not take file drags while drop sources exist")

        let folder = shell.store.directory.appendingPathComponent("drop-sample", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Itinerary.txt", isDirectory: false)
        try? Data("QNotch sample".utf8).write(to: file)
        defer {
            if let item = tray.items.first(where: { $0.url.path == file.standardizedFileURL.path }) { tray.remove(item) }
            try? FileManager.default.removeItem(at: folder)
            shell.endDropScreen()
            shell.selectTab("home")
        }

        shell.open(keyboard: false)
        shell.selectTab("home")
        shell.fileDragEntered([file], at: .zero)
        guard let screen = shell.dropScreen, let content = shell.panel.contentView else { throw NativeSmokeTest.Failure("drop-screen", "A file drag over the open panel did not show the drop screen") }
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        try require(views.contains { $0 === screen && !$0.isHiddenOrHasHiddenAncestor && $0.identifier?.rawValue == "drop-screen" }, "The drop screen is not on screen as #drop-screen")
        try require(!views.contains { $0 is TabBar && !$0.isHiddenOrHasHiddenAncestor }, "The tab strip still shows under the drop screen")
        try require(shell.isHeld, "The drop screen does not keep the panel open")
        func tile(_ id: String) -> DropTile? { screen.tiles.first { $0.identifier?.rawValue == id } }
        func center(_ tile: DropTile) -> NSPoint { tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil) }
        guard let add = tile("drop-files-add") else { throw NativeSmokeTest.Failure("drop-screen", "No File tray tile") }
        try require(add.accessibilityLabel() == "Add to tray, File tray" && add.isEnabled, "File tray tile: \(add.accessibilityLabel() ?? "unnamed"), enabled=\(add.isEnabled)")
        if shell.module(TaildropModule.self) != nil {
            guard let phone = tile("drop-taildrop-demo-pixel"), let offline = tile("drop-taildrop-demo-nas") else {
                throw NativeSmokeTest.Failure("drop-screen", "No Taildrop device tiles: \(screen.tiles.compactMap { $0.identifier?.rawValue })")
            }
            try require(phone.accessibilityLabel() == "pixel-8, Taildrop" && phone.isEnabled, "Taildrop tile is not named or enabled")
            try require(shell.fileDragUpdated(at: center(phone)) == .copy && phone.dropping, "An enabled tile does not take the drag")
            try require(!offline.isEnabled && !offline.isAccessibilityEnabled(), "The offline device tile is not disabled")
            try require(shell.fileDragUpdated(at: center(offline)) == [] && !offline.dropping && !phone.dropping, "A disabled tile does not refuse the drag")
            try require(!shell.filesDropped([file], at: center(offline)), "A disabled tile took the drop")
            try require(shell.dropScreen == nil, "A refused drop left the drop screen up")
            shell.fileDragEntered([file], at: .zero)
        }
        try require(shell.fileDragUpdated(at: NSPoint(x: 1, y: 1)) == [], "Outside every tile the drag is not refused")
        guard let addAgain = shell.dropScreen.flatMap({ s in s.tiles.first { $0.identifier?.rawValue == "drop-files-add" } }) else {
            throw NativeSmokeTest.Failure("drop-screen", "The drop screen did not come back for a second drag")
        }
        try require(shell.filesDropped([file], at: center(addAgain)), "Add to tray refused the drop")
        try require(shell.dropScreen == nil && !shell.isHeld, "The drop screen did not close after the drop")
        try require(tray.items.contains { $0.url.path == file.standardizedFileURL.path }, "The dropped file is not in the tray")
        try require(shell.activeTab == "files" && shell.state.expanded, "File tray did not open its Files tab after the drop")
        run.pass("drop-screen")
    }
}
