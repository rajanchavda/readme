import Foundation
import Testing
@testable import Readme

private func book(_ id: String) -> Book {
    Book(
        id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: 1), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

private func place(_ fraction: Double, end: Bool = false) -> ReaderLocation {
    ReaderLocation(
        cfi: "epubcfi(/6/14!/4/2/10)", fraction: fraction, chapterTitle: "Chapter 7", chapterMinutesLeft: 6,
        isAtStart: false, isAtEnd: end, page: 10, pageCount: 100)
}

/// A clock the test moves by hand.
@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1000)
}

@MainActor
@Suite struct ReadingProgressStoreTests {
    @Test func markReadCopiesProgress() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.markRead(id: "a", location: place(0.42))
        #expect(store.book(id: "a")?.progress == 0.42)
        store.markRead(id: "a", location: place(0.97, end: true))
        #expect(store.book(id: "a")?.progress == 1)
        #expect(store.book(id: "a")?.finishedAt == nil)
    }

    @Test func finishingSetsTheDateOnce() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let store = LibraryStore(directory: folder, now: { clock.now })
        store.add(book("a"))
        let first = clock.now
        store.markRead(id: "a", location: place(0.96), finishing: true)
        #expect(store.book(id: "a")?.finishedAt == first)
        clock.now = first.addingTimeInterval(60)
        store.markRead(id: "a", location: place(0.97), finishing: true)
        #expect(store.book(id: "a")?.finishedAt == first)
    }

    @Test func readingAgainNeverUnfinishes() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.markRead(id: "a", location: place(0.96), finishing: true)
        let finished = try #require(store.book(id: "a")?.finishedAt)
        store.markRead(id: "a", location: place(0.01))
        #expect(store.book(id: "a")?.finishedAt == finished)
        #expect(store.book(id: "a")?.progress == 0.01)
    }

    @Test func setFinishedOnAMixedSelection() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let store = LibraryStore(directory: folder, now: { clock.now })
        store.add(book("a"))
        store.add(book("b"))
        store.markRead(id: "a", location: place(0.5))
        let t1 = clock.now
        store.setFinished(ids: ["a"], finished: true)
        clock.now = t1.addingTimeInterval(60)
        store.setFinished(ids: ["a", "b"], finished: true)
        #expect(store.book(id: "a")?.finishedAt == t1)
        #expect(store.book(id: "b")?.finishedAt == clock.now)
        store.setFinished(ids: ["a", "b"], finished: false)
        #expect(store.books.allSatisfy { $0.finishedAt == nil })
        // Marking by hand never moves the place.
        #expect(store.book(id: "a")?.progress == 0.5)
        #expect(store.book(id: "b")?.progress == nil)
    }

    @Test func oldLibraryFileLoads() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = #"[{"id":"a","title":"A","fileName":"a.epub","hasCover":false,"addedAt":0}]"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: folder)
        #expect(store.book(id: "a")?.progress == nil)
        #expect(store.book(id: "a")?.finishedAt == nil)
    }

    @Test func savedAndReloaded() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.markRead(id: "a", location: place(0.96), finishing: true)
        await store.saved()
        let again = LibraryStore(directory: folder)
        #expect(again.book(id: "a")?.progress == 0.96)
        #expect(again.book(id: "a")?.finishedAt == store.book(id: "a")?.finishedAt)
    }

    @Test func backfillFillsOnlyMissingAndFinishesNothing() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var b = book("b")
        b.progress = 0.3
        try JSONEncoder().encode([book("a"), b]).write(to: folder.appendingPathComponent("library.json"))
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        await positions.save(place(0.98), bookID: "a")
        await positions.save(place(0.98), bookID: "b")
        let store = LibraryStore(directory: folder, positions: positions)
        #expect(store.book(id: "a")?.progress == 0.98)
        #expect(store.book(id: "b")?.progress == 0.3)
        #expect(store.books.allSatisfy { $0.finishedAt == nil })
    }

    @Test func applyImportedSetsProgress() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.applyImported(id: "a", addedAt: nil, lastReadAt: nil, location: place(0.6))
        #expect(store.book(id: "a")?.progress == 0.6)
    }

    @Test func restoreFinishedNeverMovesADate() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        let first = Date(timeIntervalSince1970: 500)
        store.restoreFinished(id: "a", at: first)
        #expect(store.book(id: "a")?.finishedAt == first)
        store.restoreFinished(id: "a", at: Date(timeIntervalSince1970: 900))
        #expect(store.book(id: "a")?.finishedAt == first)
    }
}
