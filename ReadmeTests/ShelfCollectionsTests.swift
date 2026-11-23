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

    @Test func copy() {
        #expect(ShelfCollections.emptyLine(name: "Self-Help")
            == "No books in Self-Help yet. Right-click a book and choose Add to Collection.")
        let many = ShelfCollections.deleteText(name: "Self-Help", count: 12)
        #expect(many.title == "Delete Self-Help?")
        #expect(many.message == "The 12 books in it stay in your library.")
        #expect(ShelfCollections.deleteText(name: "Self-Help", count: 1).message == "The 1 book in it stays in your library.")
    }
}
