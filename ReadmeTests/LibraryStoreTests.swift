import Foundation
import Testing
@testable import Readme

/// A new, empty folder for one test's library.
func libraryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func book(_ id: String, added: Double, read: Double? = nil) -> Book {
    Book(
        id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: added),
        lastReadAt: read.map { Date(timeIntervalSince1970: $0) },
        chapterTitle: nil, chapterMinutesLeft: nil)
}

private let place = ReaderLocation(
    cfi: "epubcfi(/6/14!/4/2/10)", fraction: 0.42, chapterTitle: "Chapter 7",
    chapterMinutesLeft: 6.5, isAtStart: false, isAtEnd: false, page: 210, pageCount: 500)

@MainActor
@Suite struct LibraryStoreTests {
    @Test func currentIsMostRecentlyRead() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a", added: 1, read: 50))
        store.add(book("b", added: 2, read: 70))
        store.add(book("c", added: 3))
        #expect(store.current?.id == "b")
    }

    @Test func othersSortedByRecency() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("read-early", added: 1, read: 10))
        store.add(book("read-late", added: 2, read: 90))
        store.add(book("new", added: 60))
        store.add(book("old", added: 5))
        store.add(book("current", added: 3, read: 100))
        #expect(store.current?.id == "current")
        // A book never read counts from when it was added.
        #expect(store.others.map(\.id) == ["read-late", "new", "read-early", "old"])
    }

    @Test func noReadBooksMeansNewestIsCurrent() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        #expect(store.current == nil)
        store.add(book("a", added: 1))
        store.add(book("c", added: 3))
        store.add(book("b", added: 2))
        #expect(store.current?.id == "c")
        #expect(store.others.map(\.id) == ["b", "a"])
    }

    @Test func markReadRecordsWhereTheReaderIs() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let moment = Date(timeIntervalSince1970: 500)
        let store = LibraryStore(directory: folder, now: { moment })
        store.add(book("a", added: 1))
        store.markRead(id: "a", location: place)
        #expect(store.books.first?.lastReadAt == moment)
        #expect(store.books.first?.chapterTitle == "Chapter 7")
        #expect(store.books.first?.chapterMinutesLeft == 6.5)
    }

    @Test func survivesRestart() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a", added: 1))
        store.markRead(id: "a", location: place)
        await store.saved()
        #expect(LibraryStore(directory: folder).books == store.books)
    }

    @Test func removeDeletesCopyAndPosition() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions"))
        let store = LibraryStore(directory: folder, positions: positions)
        let gone = book("gone", added: 1)
        let kept = book("kept", added: 2)
        for each in [gone, kept] {
            store.add(each)
            try FileManager.default.createDirectory(
                at: store.fileURL(for: each).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: store.coverURL(for: each).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("book".utf8).write(to: store.fileURL(for: each))
            try Data("cover".utf8).write(to: store.coverURL(for: each))
            await positions.save(place, bookID: each.id)
        }
        store.remove(id: "gone")
        await store.removed()
        await store.saved()
        #expect(store.books.map(\.id) == ["kept"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: gone).path))
        #expect(!FileManager.default.fileExists(atPath: store.coverURL(for: gone).path))
        #expect(await positions.location(bookID: "gone") == nil)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: kept).path))
        #expect(await positions.location(bookID: "kept") == place)
        #expect(LibraryStore(directory: folder).books.map(\.id) == ["kept"])
    }

    @Test func corruptLibraryFileStartsEmpty() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("{ not json".utf8).write(to: folder.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: folder)
        #expect(store.books.isEmpty)
        store.add(book("a", added: 1))
        await store.saved()
        #expect(LibraryStore(directory: folder).books.map(\.id) == ["a"])
    }

    // MARK: Pins

    /// A store whose clock reads whatever `clock` is set to.
    private final class Clock: @unchecked Sendable {
        var time: Double = 1000
    }

    private func pinStore(_ folder: URL, _ clock: Clock) -> LibraryStore {
        let store = LibraryStore(directory: folder, now: { Date(timeIntervalSince1970: clock.time) })
        store.add(book("current", added: 1, read: 500))
        store.add(book("a", added: 2, read: 100))
        store.add(book("b", added: 3, read: 200))
        store.add(book("c", added: 4, read: 300))
        store.add(book("d", added: 5, read: 400))
        return store
    }

    @Test func pinnedComeFirstNewestPinFirst() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let store = pinStore(folder, clock)
        #expect(store.others.map(\.id) == ["d", "c", "b", "a"])
        store.setPinned(ids: ["a"], pinned: true)
        clock.time = 1001
        store.setPinned(ids: ["b"], pinned: true)
        #expect(store.others.map(\.id) == ["b", "a", "d", "c"])
        #expect(store.book(id: "b")?.pinnedAt == Date(timeIntervalSince1970: 1001))
        // Reading a pinned book doesn't reorder the pins.
        clock.time = 1002
        store.markRead(id: "a", location: place)
        clock.time = 1003
        store.markRead(id: "current", location: place)
        #expect(store.others.map(\.id) == ["b", "a", "d", "c"])
    }

    @Test func unpinnedGoBackByRecency() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = pinStore(folder, Clock())
        store.setPinned(ids: ["a", "b"], pinned: true)
        store.setPinned(ids: ["a", "b"], pinned: false)
        #expect(store.others.map(\.id) == ["d", "c", "b", "a"])
        #expect(store.books.allSatisfy { $0.pinnedAt == nil })
    }

    @Test func pinningAgainKeepsTheDate() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = Clock()
        let store = pinStore(folder, clock)
        store.setPinned(ids: ["a"], pinned: true)
        clock.time = 1001
        store.setPinned(ids: ["b"], pinned: true)
        clock.time = 1002
        // A mixed selection: "a" is pinned already and keeps its place behind "b".
        store.setPinned(ids: ["a", "c"], pinned: true)
        #expect(store.book(id: "a")?.pinnedAt == Date(timeIntervalSince1970: 1000))
        #expect(store.others.map(\.id) == ["c", "b", "a", "d"])
    }

    @Test func currentBookPinnedIsOnlyOnTheLedge() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = pinStore(folder, Clock())
        store.setPinned(ids: ["current", "a"], pinned: true)
        #expect(store.current?.id == "current")
        #expect(store.others.map(\.id) == ["a", "d", "c", "b"])
    }

    @Test func pinningAMissingBookDoesNothing() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = pinStore(folder, Clock())
        let before = store.books
        store.setPinned(ids: ["gone"], pinned: true)
        store.restorePin(id: "gone", at: Date(timeIntervalSince1970: 1))
        #expect(store.books == before)
    }

    @Test func restorePinKeepsTheGivenDate() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = pinStore(folder, Clock())
        store.setPinned(ids: ["a"], pinned: true)
        store.restorePin(id: "b", at: Date(timeIntervalSince1970: 1))
        #expect(store.book(id: "b")?.pinnedAt == Date(timeIntervalSince1970: 1))
        #expect(store.others.map(\.id) == ["a", "b", "d", "c"])
    }

    @Test func pinsSurviveRestart() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = pinStore(folder, Clock())
        store.setPinned(ids: ["a"], pinned: true)
        await store.saved()
        let reopened = LibraryStore(directory: folder)
        #expect(reopened.book(id: "a")?.pinnedAt == Date(timeIntervalSince1970: 1000))
        #expect(reopened.others.map(\.id) == ["a", "d", "c", "b"])
    }

    @Test func oldLibraryFileLoadsUnpinned() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // As written before books could be pinned.
        let json = #"[{"id":"a","title":"A","fileName":"a.epub","hasCover":false,"addedAt":10}]"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: folder)
        #expect(store.books.map(\.id) == ["a"])
        #expect(store.book(id: "a")?.pinnedAt == nil)
    }
}
