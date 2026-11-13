import Foundation
import Testing
@testable import Readme

private final class GoldenToken {}

/// A file from `Fixtures/Golden`, which the Windows app's tests read too (see its README).
private func golden(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: GoldenToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent("Golden").appendingPathComponent(name)
}

private func fixtureURL(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: GoldenToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The formats both apps share. If one of these fails, the Windows app can no longer read what this
/// one writes, or the reverse: change both apps and the golden files together.
@Suite struct GoldenFilesTests {
    private func iso(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    @MainActor
    @Test func libraryFileLoads() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: golden("library.json"), to: folder.appendingPathComponent("library.json"))
        let books = LibraryStore(directory: folder).books
        #expect(books.count == 2)
        let long = try #require(books.first)
        #expect(long.id == "94d86ef4fdd170a2f2714779a4ad0ae759f882d0edba9ded1579cc64691b10cb")
        #expect(long.title == "Long Book")
        #expect(long.author == "A. Writer")
        #expect(long.hasCover)
        #expect(long.addedAt == Date(timeIntervalSinceReferenceDate: 784_000_000))
        #expect(long.lastReadAt == Date(timeIntervalSinceReferenceDate: 784_500_000.5))
        #expect(long.chapterTitle == "Chapter 3")
        #expect(long.chapterMinutesLeft == 7.25)
        #expect(long.pinnedAt == nil)
        let pinned = books[1]
        #expect(pinned.title == "Les Misérables")
        #expect(pinned.author == nil)
        #expect(pinned.lastReadAt == nil)
        #expect(pinned.pinnedAt == Date(timeIntervalSinceReferenceDate: 784_600_000))
    }

    @Test func highlightsLoad() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: golden("highlights.json"), to: folder.appendingPathComponent("book.json"))
        let highlights = await HighlightStore(directory: folder).highlights(bookID: "book")
        #expect(highlights.map(\.id.uuidString) == [
            "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", "0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9",
        ])
        #expect(highlights[0].cfi == "epubcfi(/6/4!/4/2,/1:0,/1:12)")
        #expect(highlights[0].created == (try iso("2026-11-13T09:30:00Z")))
        #expect(highlights[1].text == "Ünïcödé — and “quotes”")
        #expect(highlights[1].chapterTitle == nil)
    }

    @Test func markerLoads() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: golden("marker.json"), to: folder.appendingPathComponent("book.json"))
        let marker = try #require(await MarkerStore(directory: folder).marker(bookID: "book"))
        #expect(marker == Marker(
            cfi: "epubcfi(/6/8!/4/2/1:0)", fraction: 0.4, page: 120, chapterTitle: "Chapter 4",
            created: try iso("2026-11-13T10:00:00Z")))
    }

    @Test func positionLoads() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: golden("position.json"), to: folder.appendingPathComponent("book.json"))
        let location = await PositionStore(directory: folder).location(bookID: "book")
        #expect(location == ReaderLocation(
            cfi: "epubcfi(/6/14!/4/2/10,/1:12,/3:40)", fraction: 0.42, chapterTitle: "Chapter 7",
            chapterMinutesLeft: 6.5, isAtStart: false, isAtEnd: false, page: 210, pageCount: 500, isMarked: true))
    }

    /// A bundle exported by the Windows app (GoldenFilesTests.cs writes it byte for byte).
    @Test func windowsBundleOpens() async throws {
        let url = try golden("windows.readmelibrary")
        let id = try await BookID.of(fixtureURL("no-cover.epub"))
        let opened = try LibraryBundle.open(url)
        #expect(opened.manifest == BundleManifest(formatVersion: 1, exportedAt: try iso("2026-11-13T10:00:00Z"), bookIDs: [id]))
        let contents = try opened.contents(of: id)
        #expect(contents.info == BundledBook(
            title: "No Cover, from Windows", author: "Fixture Author", addedAt: try iso("2026-11-13T08:00:00Z"),
            lastReadAt: try iso("2026-11-13T09:00:00Z"), pinnedAt: try iso("2026-11-13T08:30:00Z")))
        #expect(contents.highlights == [Highlight(
            id: try #require(UUID(uuidString: "5B2E8F14-7A3C-4D1E-9F60-2C8B4A7D3E91")), cfi: "epubcfi(/6/4!/4/2,/1:0,/1:9)",
            text: "Ünïcödé — “quoted”", chapterTitle: "Chapter 1", fraction: 0.25, created: try iso("2026-11-13T09:15:00Z"))])
        #expect(contents.marker == Marker(
            cfi: "epubcfi(/6/4!/4/2/1:0)", fraction: 0.25, page: 3, chapterTitle: "Chapter 1",
            created: try iso("2026-11-13T09:20:00Z")))
        #expect(contents.position == ReaderLocation(
            cfi: "epubcfi(/6/4!/4/2/1:0)", fraction: 0.25, chapterTitle: "Chapter 1", chapterMinutesLeft: 2.5,
            isAtStart: false, isAtEnd: false, page: 3, pageCount: 9, isMarked: true))
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("book.epub")
        try opened.extractEPUB(of: id, to: out)
        #expect(try await BookID.of(out) == id)
    }

    @Test func bookIDsMatchWindows() async throws {
        let ids = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: golden("ids.json")))
        #expect(ids.count == 3)
        for (name, id) in ids {
            #expect(try await BookID.of(fixtureURL(name)) == id, "\(name)")
        }
    }
}
