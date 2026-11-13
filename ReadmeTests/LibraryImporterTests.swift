import Foundation
import Testing
@testable import Readme

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct LibraryImporterTests {
    let folder: URL
    /// The Mac the bundle comes from, and the one it goes to.
    let storeA: LibraryStore
    let storeB: LibraryStore
    let importerB: LibraryImporter
    let url: URL

    let h = Highlight(cfi: "epubcfi(/6/4!/4,/1:0,/1:4)", text: "from A", fraction: 0.3, created: bundleDate(100))
    let h2 = Highlight(cfi: "epubcfi(/6/2!/4,/1:0,/1:4)", text: "from B", fraction: 0.1, created: bundleDate(200))
    let m = Marker(cfi: "epubcfi(/6/6!/4/2/1:0)", fraction: 0.4, page: 9, created: bundleDate(300))
    let m2 = Marker(cfi: "epubcfi(/6/8!/4/2/1:0)", fraction: 0.6, page: 20, created: bundleDate(400))

    init() throws {
        folder = try libraryFolder()
        storeA = LibraryStore(directory: folder.appendingPathComponent("A", isDirectory: true))
        storeB = LibraryStore(directory: folder.appendingPathComponent("B", isDirectory: true))
        importerB = LibraryImporter(store: storeB, importer: BookImporter(store: storeB))
        url = folder.appendingPathComponent("out.readmelibrary")
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    /// long.epub on Mac A with h, m and a place halfway, added at 1000 and read at 2000, exported.
    @discardableResult
    private func exportFromA(pinnedAt: Date? = nil) async throws -> String {
        let book = try await BookImporter(store: storeA).importBook(from: exportFixture("long.epub"))
        storeA.applyImported(id: book.id, addedAt: bundleDate(1000), lastReadAt: bundleDate(2000), location: nil)
        if let pinnedAt { storeA.restorePin(id: book.id, at: pinnedAt) }
        await storeA.highlights.add(h, bookID: book.id)
        await storeA.markers.set(m, bookID: book.id)
        await storeA.positions.save(bundlePlace(0.5), bookID: book.id)
        _ = try await LibraryExporter(store: storeA).export(storeA.books, to: url)
        return book.id
    }

    /// long.epub already on Mac B, with h2, m2 and a place `fraction` of the way through.
    private func haveOnB(fraction: Double) async throws -> String {
        let book = try await BookImporter(store: storeB).importBook(from: exportFixture("long.epub"))
        await storeB.highlights.add(h2, bookID: book.id)
        await storeB.markers.set(m2, bookID: book.id)
        await storeB.positions.save(bundlePlace(fraction), bookID: book.id)
        return book.id
    }

    @Test func newBooksComeInWithEverything() async throws {
        defer { clean() }
        let id = try await exportFromA()
        let prepared = try await importerB.prepare(url)
        #expect(prepared.newIDs == [id])
        #expect(prepared.existingIDs.isEmpty)
        #expect(await importerB.run(prepared, choice: .keepMine) == ImportSummary(added: 1))
        let book = try #require(storeB.book(id: id))
        #expect(book.addedAt == bundleDate(1000))
        #expect(book.lastReadAt == bundleDate(2000))
        #expect(book.chapterTitle == "Chapter 1")
        #expect(await storeB.highlights.highlights(bookID: id) == [h])
        #expect(await storeB.markers.marker(bookID: id) == m)
        #expect(await storeB.positions.location(bookID: id) == bundlePlace(0.5))
        #expect(FileManager.default.fileExists(atPath: storeB.coverURL(for: book).path))
    }

    /// The title and author the shelf showed on the other Mac, not the file's own or its staged name.
    @Test func newBooksKeepTheirShelfTitle() async throws {
        defer { clean() }
        let epub = try exportFixture("no-cover.epub")
        let id = try await BookID.of(epub)
        try LibraryBundle.write([
            BundleItem(id: id, info: BundledBook(title: "Shelf Title", author: "Shelf Author", addedAt: bundleDate(1), lastReadAt: nil),
                       epub: epub, highlights: [], marker: nil, position: nil),
        ], to: url, exportedAt: bundleDate(1))
        _ = await importerB.run(try await importerB.prepare(url), choice: .keepMine)
        #expect(storeB.book(id: id)?.title == "Shelf Title")
        #expect(storeB.book(id: id)?.author == "Shelf Author")
    }

    @Test func newBooksKeepTheirPin() async throws {
        defer { clean() }
        let id = try await exportFromA(pinnedAt: bundleDate(3000))
        _ = await importerB.run(try await importerB.prepare(url), choice: .keepMine)
        #expect(storeB.book(id: id)?.pinnedAt == bundleDate(3000))
    }

    @Test(arguments: [ImportChoice.keepMine, .combine])
    func existingBooksKeepTheirOwnPin(choice: ImportChoice) async throws {
        defer { clean() }
        // Pinned there, not here: stays unpinned.
        let id = try await exportFromA(pinnedAt: bundleDate(3000))
        _ = try await haveOnB(fraction: 0.2)
        _ = await importerB.run(try await importerB.prepare(url), choice: choice)
        #expect(storeB.book(id: id)?.pinnedAt == nil)
        // Pinned here, not there: stays pinned, with its own date.
        storeB.restorePin(id: id, at: bundleDate(4000))
        storeA.setPinned(ids: [id], pinned: false)
        _ = try await LibraryExporter(store: storeA).export(storeA.books, to: url)
        _ = await importerB.run(try await importerB.prepare(url), choice: choice)
        #expect(storeB.book(id: id)?.pinnedAt == bundleDate(4000))
    }

    @Test func keepMineLeavesExistingBooksAlone() async throws {
        defer { clean() }
        let id = try await exportFromA()
        _ = try await haveOnB(fraction: 0.2)
        let before = storeB.books
        let prepared = try await importerB.prepare(url)
        #expect(prepared.existingIDs == [id])
        #expect(await importerB.run(prepared, choice: .keepMine) == ImportSummary(kept: 1))
        #expect(storeB.books == before)
        #expect(await storeB.highlights.highlights(bookID: id) == [h2])
        #expect(await storeB.markers.marker(bookID: id) == m2)
        #expect(await storeB.positions.location(bookID: id) == bundlePlace(0.2))
    }

    @Test func combineAddsHighlightsAndTheFurtherPlace() async throws {
        defer { clean() }
        let id = try await exportFromA()
        _ = try await haveOnB(fraction: 0.2)
        let prepared = try await importerB.prepare(url)
        #expect(await importerB.run(prepared, choice: .combine) == ImportSummary(combined: 1))
        #expect(await storeB.highlights.highlights(bookID: id) == [h2, h])
        #expect(await storeB.markers.marker(bookID: id) == m2)
        #expect(await storeB.positions.location(bookID: id) == bundlePlace(0.5))
        #expect(storeB.book(id: id)?.lastReadAt == bundleDate(2000))
    }

    @Test func combineKeepsTheFurtherPlaceHere() async throws {
        defer { clean() }
        let id = try await exportFromA()
        _ = try await haveOnB(fraction: 0.9)
        let prepared = try await importerB.prepare(url)
        _ = await importerB.run(prepared, choice: .combine)
        #expect(await storeB.positions.location(bookID: id) == bundlePlace(0.9))
    }

    @Test func importingTwiceChangesNothing() async throws {
        defer { clean() }
        let id = try await exportFromA()
        _ = await importerB.run(try await importerB.prepare(url), choice: .combine)
        let books = storeB.books
        #expect(await importerB.run(try await importerB.prepare(url), choice: .combine) == ImportSummary(combined: 1))
        #expect(storeB.books == books)
        #expect(await storeB.highlights.highlights(bookID: id) == [h])
    }

    @Test func aBadBookInTheBundleIsSkipped() async throws {
        defer { clean() }
        let drm = try exportFixture("drm.epub")
        let long = try exportFixture("long.epub")
        let info = BundledBook(title: "T", author: nil, addedAt: bundleDate(1), lastReadAt: nil)
        try LibraryBundle.write([
            BundleItem(id: try await BookID.of(drm), info: info, epub: drm, highlights: [], marker: nil, position: nil),
            BundleItem(id: try await BookID.of(long), info: info, epub: long, highlights: [], marker: nil, position: nil),
        ], to: url, exportedAt: bundleDate(1))
        let summary = await importerB.run(try await importerB.prepare(url), choice: .keepMine)
        #expect(summary == ImportSummary(added: 1, failed: 1))
        #expect(storeB.books.map(\.id) == [try await BookID.of(long)])
    }

    @Test func aBookWhoseFileDoesntMatchItsIDIsSkipped() async throws {
        defer { clean() }
        let info = BundledBook(title: "T", author: nil, addedAt: bundleDate(1), lastReadAt: nil)
        try LibraryBundle.write([
            BundleItem(id: String(repeating: "a", count: 64), info: info, epub: try exportFixture("long.epub"),
                       highlights: [h], marker: nil, position: nil),
        ], to: url, exportedAt: bundleDate(1))
        let summary = await importerB.run(try await importerB.prepare(url), choice: .keepMine)
        #expect(summary == ImportSummary(failed: 1))
        #expect(storeB.books.isEmpty)
    }

    @Test func noLeftoverStagingFiles() async throws {
        defer { clean() }
        try await exportFromA()
        _ = await importerB.run(try await importerB.prepare(url), choice: .keepMine)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: storeB.booksDirectory.path)) ?? []
        #expect(!left.contains { $0.hasPrefix(".bundle-") || $0.hasPrefix(".importing-") })
    }

    @Test func summaryLines() {
        #expect(ImportSummary(added: 4, combined: 2, failed: 1).line == "Added 4 books, combined 2, 1 couldn't be read")
        #expect(ImportSummary(added: 1).line == "Added 1 book")
        #expect(ImportSummary(kept: 2).line == "Left 2 as they were")
        #expect(ImportSummary(combined: 1, kept: 1).line == "Combined 1, left 1 as they were")
        #expect(ImportSummary(failed: 3).line == "3 couldn't be read")
        #expect(ImportSummary().line == "Nothing to import")
    }
}
