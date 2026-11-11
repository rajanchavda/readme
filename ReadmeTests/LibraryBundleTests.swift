import Foundation
import Testing
@testable import Readme

/// A place `fraction` of the way through a book, for the export and import tests.
func bundlePlace(_ fraction: Double, chapter: String? = "Chapter 1") -> ReaderLocation {
    ReaderLocation(
        cfi: "epubcfi(/6/4!/4/2/1:0)", fraction: fraction, chapterTitle: chapter, chapterMinutesLeft: 3,
        isAtStart: false, isAtEnd: false, page: 12, pageCount: 40)
}

/// A date that survives an ISO 8601 round trip.
func bundleDate(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

@Suite struct LibraryBundleTests {
    let folder: URL
    let url: URL

    init() throws {
        folder = try libraryFolder()
        url = folder.appendingPathComponent("out.readmelibrary")
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    private func item(id: String, epub: URL, highlights: [Highlight] = [], marker: Marker? = nil,
                      position: ReaderLocation? = nil) -> BundleItem {
        BundleItem(
            id: id, info: BundledBook(title: "Long", author: "Someone", addedAt: bundleDate(1000), lastReadAt: bundleDate(2000)),
            epub: epub, highlights: highlights, marker: marker, position: position)
    }

    /// A zip with just this manifest in it.
    private func writeManifest(_ json: String, extra: [String: Data] = [:]) throws {
        let writer = try ZipWriter(url: url)
        try writer.add("manifest.json", data: Data(json.utf8))
        for (name, data) in extra { try writer.add(name, data: data) }
        try writer.finish()
    }

    @Test func roundTripsEveryPart() async throws {
        defer { clean() }
        let epub = try exportFixture("long.epub")
        let id = try await BookID.of(epub)
        let two = [
            Highlight(cfi: "epubcfi(/6/2!/4,/1:0,/1:4)", text: "one", chapterTitle: "1", fraction: 0.1, created: bundleDate(10)),
            Highlight(cfi: "epubcfi(/6/4!/4,/1:0,/1:4)", text: "two", chapterTitle: nil, fraction: 0.3, created: bundleDate(20)),
        ]
        let marker = Marker(cfi: "epubcfi(/6/6!/4/2/1:0)", fraction: 0.4, page: 9, chapterTitle: "2", created: bundleDate(30))
        let place = bundlePlace(0.5)
        let it = item(id: id, epub: epub, highlights: two, marker: marker, position: place)
        try LibraryBundle.write([it], to: url, exportedAt: bundleDate(5000))

        let opened = try LibraryBundle.open(url)
        #expect(opened.manifest == BundleManifest(formatVersion: 1, exportedAt: bundleDate(5000), bookIDs: [id]))
        #expect(try opened.contents(of: id) == BundleContents(info: it.info, highlights: two, marker: marker, position: place))
        let out = folder.appendingPathComponent("book.epub")
        try opened.extractEPUB(of: id, to: out)
        #expect(try Data(contentsOf: out) == (try Data(contentsOf: epub)))
    }

    @Test func noMarkerOrPositionReadsAsNil() async throws {
        defer { clean() }
        let epub = try exportFixture("long.epub")
        let id = try await BookID.of(epub)
        try LibraryBundle.write([item(id: id, epub: epub)], to: url, exportedAt: bundleDate(1))
        let contents = try LibraryBundle.open(url).contents(of: id)
        #expect(contents.marker == nil)
        #expect(contents.position == nil)
        #expect(contents.highlights.isEmpty)
    }

    @Test func refusesANewerVersion() throws {
        defer { clean() }
        try writeManifest(#"{"formatVersion":2,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":[]}"#)
        #expect(throws: BundleError.newerVersion) { try LibraryBundle.open(url) }
    }

    @Test func anEPUBIsNotABundle() throws {
        #expect(throws: BundleError.notABundle) { try LibraryBundle.open(exportFixture("long.epub")) }
    }

    @Test func rejectsIDsThatArentHashes() throws {
        defer { clean() }
        try writeManifest(
            #"{"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":["../../x"]}"#,
            extra: ["books/../../x/book.json": Data("{}".utf8), "books/../../x/book.epub": Data()])
        #expect(throws: BundleError.notABundle) { try LibraryBundle.open(url) }
    }

    @Test func aListedBookWithoutItsFileIsNotABundle() throws {
        defer { clean() }
        let id = String(repeating: "a", count: 64)
        try writeManifest(
            #"{"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","bookIDs":["\#(id)"]}"#,
            extra: ["books/\(id)/book.json": Data(#"{"title":"T","addedAt":"2026-01-01T00:00:00Z"}"#.utf8)])
        #expect(throws: BundleError.notABundle) { try LibraryBundle.open(url) }
    }

    @Test func messages() {
        #expect(BundleError.notABundle.message == "This file isn't a Readme library.")
        #expect(BundleError.newerVersion.message == "This library was made by a newer Readme. Update Readme to import it.")
        #expect(BundleError.tooLarge.message == "That's more than 4 GB, too much for one file. Export fewer books at a time.")
        #expect(BundleError.unwritable.message == "The export couldn't be saved.")
    }
}
