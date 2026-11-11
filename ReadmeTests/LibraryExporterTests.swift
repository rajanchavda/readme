import Foundation
import Testing
@testable import Readme

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct LibraryExporterTests {
    let folder: URL
    let store: LibraryStore
    let url: URL

    init() throws {
        folder = try libraryFolder()
        store = LibraryStore(directory: folder.appendingPathComponent("Library", isDirectory: true))
        url = folder.appendingPathComponent("out.readmelibrary")
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    @Test func exportsBooksWithTheirNotes() async throws {
        defer { clean() }
        let book = try await BookImporter(store: store).importBook(from: exportFixture("long.epub"))
        await store.highlights.add(Highlight(cfi: "epubcfi(/6/2!/4,/1:0,/1:4)", text: "w", fraction: 0.1), bookID: book.id)
        await store.markers.set(Marker(cfi: "epubcfi(/6/4!/4/2/1:0)", fraction: 0.2, page: 4), bookID: book.id)
        await store.positions.save(bundlePlace(0.5), bookID: book.id)

        let summary = try await LibraryExporter(store: store).export(store.books, to: url)
        #expect(summary == ExportSummary(exported: 1, missing: 0))
        let opened = try LibraryBundle.open(url)
        #expect(opened.manifest.bookIDs == [book.id])
        let contents = try opened.contents(of: book.id)
        #expect(contents.highlights.count == 1)
        #expect(contents.marker != nil)
        #expect(contents.position == bundlePlace(0.5))
        #expect(contents.info.title == "Long Fixture Book")
        #expect(contents.info.addedAt.timeIntervalSince1970.rounded(.down) == book.addedAt.timeIntervalSince1970.rounded(.down))
    }

    @Test func aMissingFileIsLeftOutAndCounted() async throws {
        defer { clean() }
        let importer = BookImporter(store: store)
        let long = try await importer.importBook(from: exportFixture("long.epub"))
        let search = try await importer.importBook(from: exportFixture("search.epub"))
        try FileManager.default.removeItem(at: store.fileURL(for: search))

        let summary = try await LibraryExporter(store: store).export(store.books, to: url)
        #expect(summary == ExportSummary(exported: 1, missing: 1))
        #expect(try LibraryBundle.open(url).manifest.bookIDs == [long.id])
    }

    @Test func nothingToExportFails() async throws {
        defer { clean() }
        await #expect(throws: BundleError.unwritable) { try await LibraryExporter(store: store).export([], to: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func summaryLines() {
        #expect(ExportSummary(exported: 1, missing: 0).line == "Exported 1 book")
        #expect(ExportSummary(exported: 12, missing: 2).line == "Exported 12 books, 2 were missing and left out")
        #expect(ExportSummary(exported: 3, missing: 1).line == "Exported 3 books, 1 was missing and left out")
    }
}
