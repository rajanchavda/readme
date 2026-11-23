import Foundation
import Testing
@testable import Readme

private func book(_ id: String, added: Double = 1) -> Book {
    Book(
        id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: added), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

/// A store over a folder holding `library.json` with `books` and, if given, `collections` written as-is.
@MainActor
private func reloaded(_ folder: URL, books: [Book], collections: Data?) throws -> LibraryStore {
    try JSONEncoder().encode(books).write(to: folder.appendingPathComponent("library.json"))
    if let collections { try collections.write(to: folder.appendingPathComponent("collections.json")) }
    return LibraryStore(directory: folder)
}

@MainActor
@Suite struct CollectionStoreTests {
    @Test func createTrimsAndCaps() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        #expect(store.createCollection(name: "  Self-Help ")?.name == "Self-Help")
        #expect(store.createCollection(name: "   ") == nil)
        let long = String(repeating: "abcde", count: 10)
        #expect(store.createCollection(name: long)?.name == String(long.prefix(40)))
        #expect(store.collections.count == 2)
    }

    @Test func duplicateNameReturnsTheExisting() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        let first = try #require(store.createCollection(name: "Self-Help"))
        #expect(store.createCollection(name: "self-help")?.id == first.id)
        #expect(store.createCollection(name: "Sélf-help")?.id == first.id)
        #expect(store.collections.count == 1)
    }

    @Test func collectionsAreAlphabetical() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.createCollection(name: "Investing")
        store.createCollection(name: "business")
        store.createCollection(name: "Fiction")
        #expect(store.collections.map(\.name) == ["business", "Fiction", "Investing"])
    }

    @Test func renameRefusesAnotherCollectionsName() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        let fiction = try #require(store.createCollection(name: "Fiction"))
        let history = try #require(store.createCollection(name: "History"))
        #expect(store.renameCollection(id: history.id, to: "fiction") == false)
        #expect(store.collections.map(\.name) == ["Fiction", "History"])
        #expect(store.renameCollection(id: history.id, to: "  ") == false)
        #expect(store.renameCollection(id: fiction.id, to: "FICTION") == true)
        #expect(store.collection(id: fiction.id)?.name == "FICTION")
    }

    @Test func deleteStripsMemberships() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.add(book("b"))
        let x = try #require(store.createCollection(name: "X"))
        store.setCollection(x.id, member: true, ids: ["a", "b"])
        store.deleteCollection(id: x.id)
        #expect(store.collections.isEmpty)
        #expect(store.books.allSatisfy { $0.collectionIDs.isEmpty })
    }

    @Test func membershipOnASelection() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        store.add(book("b"))
        store.add(book("c"))
        let x = try #require(store.createCollection(name: "X"))
        store.setCollection(x.id, member: true, ids: ["a", "b", "nope"])
        store.setCollection(x.id, member: true, ids: ["a", "b"])
        #expect(store.book(id: "a")?.collectionIDs == [x.id])
        #expect(store.book(id: "b")?.collectionIDs == [x.id])
        #expect(store.book(id: "c")?.collectionIDs == [])
        store.setCollection(x.id, member: false, ids: ["a", "b"])
        #expect(store.books.allSatisfy { $0.collectionIDs.isEmpty })
    }

    @Test func savedAndReloaded() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        let x = try #require(store.createCollection(name: "X"))
        store.setCollection(x.id, member: true, ids: ["a"])
        await store.saved()
        let again = LibraryStore(directory: folder)
        #expect(again.collections == store.collections)
        #expect(again.book(id: "a")?.collectionIDs == [x.id])
    }

    @Test func oldLibraryFileLoads() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = #"[{"id":"a","title":"A","fileName":"a.epub","hasCover":false,"addedAt":0}]"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: folder)
        #expect(store.books.map(\.id) == ["a"])
        #expect(store.book(id: "a")?.collectionIDs == [])
    }

    @Test func unknownIDsAreDropped() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = BookCollection(id: UUID(), name: "Kept", createdAt: Date(timeIntervalSince1970: 1))
        var a = book("a")
        a.collectionIDs = [UUID(), kept.id]
        let store = try reloaded(folder, books: [a], collections: try JSONEncoder().encode([kept]))
        #expect(store.book(id: "a")?.collectionIDs == [kept.id])
    }

    @Test func corruptCollectionsFileKeepsIDs() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID()
        var a = book("a")
        a.collectionIDs = [id]
        let store = try reloaded(folder, books: [a], collections: Data("not json".utf8))
        #expect(store.collections.isEmpty)
        #expect(store.book(id: "a")?.collectionIDs == [id])
    }

    @Test func joinCollectionsByName() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(book("a"))
        let investing = try #require(store.createCollection(name: "Investing"))
        store.joinCollections(named: ["INVESTING", "Travel"], id: "a")
        let travel = try #require(store.collection(named: "travel"))
        #expect(store.collections.count == 2)
        #expect(Set(store.book(id: "a")?.collectionIDs ?? []) == [investing.id, travel.id])
        // Joining again changes nothing, and never takes a book out.
        store.joinCollections(named: ["Travel"], id: "a")
        #expect(store.book(id: "a")?.collectionIDs.count == 2)
    }

    @Test func suggestionsLeaveOutExisting() {
        let existing = ["fiction", "Science"].map { BookCollection(id: UUID(), name: $0, createdAt: Date()) }
        #expect(BookCollection.suggestions(excluding: existing)
            == ["Self-Help", "Business", "Investing", "Biography", "History", "Philosophy", "Spirituality"])
    }
}
