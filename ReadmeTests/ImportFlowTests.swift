import Foundation
import Testing
@testable import Readme

private func scratchDefaults() -> UserDefaults {
    let name = "ImportFlowTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Importing from the app: the question, what the shelf says, and the book open in the reader.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct ImportFlowTests {
    let folder: URL
    let positions: PositionStore
    let library: LibraryStore
    let coordinator: AppCoordinator
    let url: URL

    init() throws {
        folder = try libraryFolder()
        positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        library = LibraryStore(directory: folder.appendingPathComponent("Library", isDirectory: true), positions: positions)
        coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        coordinator.reader.window?.setFrameAutosaveName("")
        url = folder.appendingPathComponent("in.readmelibrary")
    }

    private func clean() {
        coordinator.reader.window?.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// A bundle of these fixtures, each with `highlights` and `position`.
    private func writeBundle(_ names: [String], highlights: [Highlight] = [], position: ReaderLocation? = nil) async throws {
        var items: [BundleItem] = []
        for name in names {
            let epub = try exportFixture(name)
            items.append(BundleItem(
                id: try await BookID.of(epub),
                info: BundledBook(title: name, author: nil, addedAt: bundleDate(1), lastReadAt: bundleDate(2)),
                epub: epub, highlights: highlights, marker: nil, position: position))
        }
        try LibraryBundle.write(items, to: url, exportedAt: bundleDate(3))
    }

    @Test func questionText() {
        #expect(ImportQuestion.message(existing: 1, total: 1) == "This book is already in your library.")
        #expect(ImportQuestion.message(existing: 1, total: 4) == "1 of these books is already in your library.")
        #expect(ImportQuestion.message(existing: 3, total: 4) == "3 of these books are already in your library.")
        #expect(ImportQuestion.informative == "Keep Mine leaves your copy as it is. Combine adds the highlights you don't have and keeps whichever reading place is further along. Your copy of the book is never replaced.")
        #expect(ImportQuestion.buttons == ["Keep Mine", "Combine", "Cancel"])
    }

    @Test func cancelImportsNothing() async throws {
        defer { clean() }
        let long = try await coordinator.importer.importBook(from: exportFixture("long.epub"))
        try await writeBundle(["long.epub", "search.epub"])
        await coordinator.importBundles([url], answer: .some(nil))
        #expect(library.books.map(\.id) == [long.id])
        #expect(coordinator.drops.lines.isEmpty)
    }

    @Test func allNewIsNotAsked() async throws {
        defer { clean() }
        try await writeBundle(["long.epub"])
        await coordinator.importBundles([url])
        #expect(library.books.count == 1)
        #expect(coordinator.drops.lines == ["Added 1 book"])
    }

    @Test func combiningTheOpenBookClosesItAndKeepsTheImportedPlace() async throws {
        defer { clean() }
        let book = try await coordinator.importer.importBook(from: exportFixture("long.epub"))
        await coordinator.open(book)
        #expect(coordinator.reader.openBook?.id == book.id)
        let mark = Highlight(cfi: "epubcfi(/6/4!/4,/1:0,/1:4)", text: "w", fraction: 0.6, created: bundleDate(9))
        try await writeBundle(["long.epub"], highlights: [mark], position: bundlePlace(0.6))

        await coordinator.importBundles([url], answer: .combine)
        #expect(coordinator.reader.openBook == nil)
        #expect(coordinator.drops.lines == ["Combined 1"])
        await coordinator.prepareToQuit()
        #expect(try #require(await positions.location(bookID: book.id)).fraction >= 0.5)
        #expect(await library.highlights.highlights(bookID: book.id) == [mark])
    }

    /// A book being combined that's opened from the shelf mid-import waits for the import, so it opens
    /// on the imported place and never writes its old one over it.
    @Test func openingABookBeingCombinedWaitsForTheImport() async throws {
        defer { clean() }
        let book = try await coordinator.importer.importBook(from: exportFixture("long.epub"))
        // A real place 60% in, as the other Mac would have saved it; then this Mac is back at the start.
        await coordinator.open(book)
        let reader = coordinator.reader
        let pages = try #require(reader.location?.pageCount)
        #expect(reader.goToPage(typed: String(pages * 6 / 10)))
        await reader.settled()
        let far = try #require(reader.location)
        #expect(far.fraction >= 0.5)
        await reader.placesKept()
        reader.closeBook()
        await positions.save(bundlePlace(0), bookID: book.id)
        // Many new books first, so the import is still running when the shelf is clicked.
        try await writeBundle(["search.epub", "spreads.epub", "no-cover.epub", "long.epub"], position: far)
        let importing = Task { await coordinator.importBundles([url], answer: .combine) }
        while !coordinator.combiningIDs.contains(book.id) { await Task.yield() }
        await coordinator.open(book)
        await importing.value
        // Reading on from wherever it opened is what writes the reader's place.
        coordinator.reader.showBook(animated: false)
        coordinator.reader.turn(.forward)
        await coordinator.reader.settled()
        await coordinator.prepareToQuit()
        #expect(try #require(await positions.location(bookID: book.id)).fraction >= 0.5)
    }

    @Test func dropsAreSplitByKind() {
        let book = URL(fileURLWithPath: "/x/a.epub")
        let bundle = URL(fileURLWithPath: "/x/b.readmelibrary")
        let split = LibraryView.split([book, bundle])
        #expect(split.books == [book])
        #expect(split.bundles == [bundle])
    }

    @Test func notABundleSaysSo() async throws {
        defer { clean() }
        try FileManager.default.copyItem(at: exportFixture("long.epub"), to: url)
        await coordinator.importBundles([url])
        #expect(coordinator.drops.lines == ["This file isn't a Readme library."])
        #expect(library.books.isEmpty)
    }
}
