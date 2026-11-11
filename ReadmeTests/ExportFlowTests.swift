import Foundation
import Testing
@testable import Readme

private func scratchDefaults() -> UserDefaults {
    let name = "ExportFlowTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Exporting from the app: the shelf's books written out, and what the shelf says about it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct ExportFlowTests {
    let folder: URL
    let library: LibraryStore
    let coordinator: AppCoordinator

    init() throws {
        folder = try libraryFolder()
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        library = LibraryStore(directory: folder.appendingPathComponent("Library", isDirectory: true), positions: positions)
        coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        coordinator.reader.window?.setFrameAutosaveName("")
    }

    private func clean() {
        coordinator.reader.window?.close()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func exportWritesTheChosenBooks() async throws {
        defer { clean() }
        let long = try await coordinator.importer.importBook(from: exportFixture("long.epub"))
        _ = try await coordinator.importer.importBook(from: exportFixture("search.epub"))
        let url = folder.appendingPathComponent("out.readmelibrary")
        await coordinator.export([long], destination: url)
        #expect(try LibraryBundle.open(url).manifest.bookIDs == [long.id])
        #expect(coordinator.drops.lines == ["Exported 1 book"])
    }

    @Test func hasBooksFollowsTheLibrary() async throws {
        defer { clean() }
        #expect(coordinator.state.hasBooks == false)
        let book = try await coordinator.importer.importBook(from: exportFixture("long.epub"))
        #expect(coordinator.state.hasBooks)
        library.remove(id: book.id)
        #expect(coordinator.state.hasBooks == false)
    }

    @Test func escapeOverTheLibraryClearsTheSelection() async throws {
        defer { clean() }
        _ = coordinator.selection.click("x", modifiers: .command, order: ["x"])
        #expect(!coordinator.selection.ids.isEmpty)
        coordinator.reader.onLibraryEscape?()
        #expect(coordinator.selection.ids.isEmpty)
    }

    @Test func progressLines() {
        #expect(ShelfDrops.workingLine("Exporting", 1) == "Exporting 1 book…")
        #expect(ShelfDrops.workingLine("Importing", 12) == "Importing 12 books…")
    }
}
