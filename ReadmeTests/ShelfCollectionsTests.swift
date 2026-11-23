import Foundation
import Testing
@testable import Readme

private func book(_ id: String, in collections: [UUID] = []) -> Book {
    Book(
        id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: 1), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil,
        collectionIDs: collections)
}

@MainActor
@Suite struct ShelfCollectionsTests {
    @Test func shownKeepsOrderAndFilters() {
        let x = UUID(), y = UUID()
        let books = [book("a", in: [x]), book("b"), book("c", in: [x, y])]
        #expect(ShelfCollections.shown(books, in: x).map(\.id) == ["a", "c"])
        #expect(ShelfCollections.shown(books, in: y).map(\.id) == ["c"])
        #expect(ShelfCollections.shown(books, in: nil).map(\.id) == ["a", "b", "c"])
    }

    @Test func deletingTheActiveGoesBackToAll() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        let x = try #require(library.createCollection(name: "X"))
        let y = try #require(library.createCollection(name: "Y"))
        let collections = ShelfCollections()
        collections.activeID = x.id
        collections.delete(y.id, from: library)
        #expect(collections.activeID == x.id)
        #expect(collections.active(in: library) == x)
        collections.delete(x.id, from: library)
        #expect(collections.activeID == nil)
        #expect(library.collections.isEmpty)
    }

    @Test func activeThatIsGoneIsAll() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        let x = try #require(library.createCollection(name: "X"))
        let collections = ShelfCollections()
        collections.activeID = x.id
        library.deleteCollection(id: x.id)
        #expect(collections.active(in: library) == nil)
    }

    @Test func importedJoinTheActive() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("a"))
        library.add(book("b"))
        let x = try #require(library.createCollection(name: "X"))
        let collections = ShelfCollections()
        collections.addImported([.success(book("a")), .failure(.unreadable)], to: library)
        #expect(library.book(id: "a")?.collectionIDs == [])
        collections.activeID = x.id
        collections.addImported([.success(book("a")), .failure(.unreadable)], to: library)
        #expect(library.book(id: "a")?.collectionIDs == [x.id])
        #expect(library.book(id: "b")?.collectionIDs == [])
    }

    @Test func importedByIDJoinTheActive() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("a"))
        let x = try #require(library.createCollection(name: "X"))
        let collections = ShelfCollections()
        collections.activeID = x.id
        collections.addImported(ids: ["a", "not-here"], to: library)
        #expect(library.book(id: "a")?.collectionIDs == [x.id])
    }

    /// Shift-click picks the run of books the shelf shows, so it can't take in books a collection hides.
    @Test func shelfOrderIsWhatShows() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        let x = try #require(library.createCollection(name: "X"))
        for (id, read) in [("current", 50.0), ("in1", 40), ("out", 30), ("in2", 20)] {
            var b = book(id, in: id.hasPrefix("in") ? [x.id] : [])
            b.lastReadAt = Date(timeIntervalSince1970: read)
            library.add(b)
        }
        #expect(ShelfCollections.shelfOrder(library, filter: .all) == ["current", "in1", "out", "in2"])
        #expect(ShelfCollections.shelfOrder(library, filter: .collection(x.id)) == ["in1", "in2"])
    }

    @Test func escapeOrder() {
        let search = ShelfSearch()
        let selection = ShelfSelection()
        let collections = ShelfCollections()
        collections.activeID = UUID()
        search.open()
        search.query = "moby"
        _ = selection.click("a", modifiers: .command, order: ["a"])

        ShelfCollections.escape(search: search, selection: selection, collections: collections)
        #expect(!search.isOpen && search.query.isEmpty)
        #expect(selection.ids == ["a"])
        #expect(collections.activeID != nil)

        ShelfCollections.escape(search: search, selection: selection, collections: collections)
        #expect(selection.ids.isEmpty)
        #expect(collections.activeID != nil)

        ShelfCollections.escape(search: search, selection: selection, collections: collections)
        #expect(collections.activeID == nil)
    }

    private func reading(_ id: String, _ progress: Double?, finished: Double? = nil) -> Book {
        var b = book(id)
        b.progress = progress
        b.finishedAt = finished.map { Date(timeIntervalSince1970: $0) }
        return b
    }

    @Test func readingAndFinishedContents() {
        let books = [reading("new", nil), reading("half", 0.4), reading("done", 1, finished: 10)]
        #expect(ShelfCollections.shown(books, filter: .reading).map(\.id) == ["half"])
        #expect(ShelfCollections.shown(books, filter: .finished).map(\.id) == ["done"])
        #expect(ShelfCollections.shown(books, filter: .all).map(\.id) == ["new", "half", "done"])
    }

    @Test func finishedIsNewestFirst() {
        let books = [reading("t1", 1, finished: 1), reading("t3", 1, finished: 3), reading("t2", 1, finished: 2)]
        #expect(ShelfCollections.shown(books, filter: .finished).map(\.id) == ["t3", "t2", "t1"])
    }

    @Test func builtInChipsHideWhenEmpty() {
        #expect(ShelfCollections.builtInChips([reading("new", nil)]) == [])
        #expect(ShelfCollections.builtInChips([reading("half", 0.4)]) == [.reading])
        #expect(ShelfCollections.builtInChips([reading("done", 1, finished: 1)]) == [.finished])
        #expect(ShelfCollections.builtInChips([reading("done", 1, finished: 1), reading("half", 0.4)]) == [.reading, .finished])
    }

    @Test func aBuiltInChipThatEmptiesGoesBackToAll() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(reading("half", 0.4))
        let collections = ShelfCollections()
        collections.filter = .reading
        #expect(collections.filter(in: library) == .reading)
        library.setFinished(ids: ["half"], finished: true)
        #expect(collections.filter(in: library) == .all)
        collections.filter = .finished
        #expect(collections.filter(in: library) == .finished)
        library.setFinished(ids: ["half"], finished: false)
        #expect(collections.filter(in: library) == .all)
    }

    /// Once its chip has gone, a built-in filter is let go of, so it doesn't come back on by itself
    /// when the chip does.
    @Test func anEmptiedBuiltInIsLetGo() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(reading("half", 0.4))
        library.add(reading("new", nil))
        let collections = ShelfCollections()
        collections.filter = .reading
        library.setFinished(ids: ["half"], finished: true)
        collections.settle(in: library)
        #expect(collections.filter == .all)
        library.markRead(id: "new", location: ReaderLocation(
            cfi: "epubcfi(/6/2!/4)", fraction: 0.1, chapterTitle: nil, chapterMinutesLeft: 1,
            isAtStart: false, isAtEnd: false, page: 1, pageCount: 10))
        #expect(collections.filter(in: library) == .all)
    }

    @Test func activeIDFollowsTheFilter() {
        let collections = ShelfCollections()
        let x = UUID()
        collections.activeID = x
        #expect(collections.filter == .collection(x))
        collections.filter = .finished
        #expect(collections.activeID == nil)
        collections.activeID = nil
        #expect(collections.filter == .all)
    }

    @Test func chipRowShowsOnceABookIsOpened() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(reading("a", nil))
        #expect(!ShelfCollections.showsChipRow(library))
        library.markRead(id: "a", location: ReaderLocation(
            cfi: "epubcfi(/6/2!/4)", fraction: 0, chapterTitle: nil, chapterMinutesLeft: 1,
            isAtStart: true, isAtEnd: false, page: 1, pageCount: 10))
        #expect(ShelfCollections.showsChipRow(library))
    }

    @Test func shelfOrderUnderFinished() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        for (id, read, finished) in [("current", 50.0, 1.0), ("old", 40, 2), ("open", 30, nil), ("newest", 20, 3)] {
            var b = reading(id, 1, finished: finished)
            b.lastReadAt = Date(timeIntervalSince1970: read)
            library.add(b)
        }
        #expect(ShelfCollections.shelfOrder(library, filter: .finished) == ["current", "newest", "old"])
    }

    @Test func escapeGoesBackToAllFromABuiltIn() {
        let collections = ShelfCollections()
        collections.filter = .finished
        ShelfCollections.escape(search: ShelfSearch(), selection: ShelfSelection(), collections: collections)
        #expect(collections.filter == .all)
    }

    @Test func copy() {
        #expect(ShelfCollections.emptyLine(name: "Self-Help")
            == "No books in Self-Help yet. Right-click a book and choose Add to Collection.")
        let many = ShelfCollections.deleteText(name: "Self-Help", count: 12)
        #expect(many.title == "Delete Self-Help?")
        #expect(many.message == "The 12 books in it stay in your library.")
        #expect(ShelfCollections.deleteText(name: "Self-Help", count: 1).message == "The 1 book in it stays in your library.")
    }
}
