import Foundation
import Testing
@testable import Readme

private func marker(_ cfi: String, page: Int = 12) -> Marker {
    Marker(cfi: cfi, fraction: 0.2, page: page, chapterTitle: "Chapter 2")
}

@Suite struct MarkerStoreTests {
    @Test func setAndRead() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        #expect(await store.marker(bookID: "book") == nil)
        let one = marker("epubcfi(/6/8!/4/2/1:0)")
        await store.set(one, bookID: "book")
        #expect(await store.marker(bookID: "book") == one)
        #expect(await store.marker(bookID: "other") == nil)
    }

    @Test func survivesRestart() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = marker("epubcfi(/6/8!/4/2/1:0)")
        await MarkerStore(directory: folder).set(one, bookID: "book")
        #expect(await MarkerStore(directory: folder).marker(bookID: "book") == one)
    }

    /// One marker a book: setting it again moves it.
    @Test func settingAgainReplaces() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        await store.set(marker("epubcfi(/6/8!/4/2/1:0)", page: 12), bookID: "book")
        let moved = marker("epubcfi(/6/10!/4/2/1:0)", page: 30)
        await store.set(moved, bookID: "book")
        #expect(await store.marker(bookID: "book") == moved)
    }

    @Test func removeDeletesIt() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        await store.set(marker("epubcfi(/6/8!/4/2/1:0)"), bookID: "book")
        await store.remove(bookID: "book")
        #expect(await store.marker(bookID: "book") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func corruptFileIsIgnored() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        await store.set(marker("epubcfi(/6/8!/4/2/1:0)"), bookID: "book")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try Data("not json".utf8).write(to: file)
        }
        #expect(await store.marker(bookID: "book") == nil)
    }

    @Test func oddIDsGetFilesOfTheirOwn() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        let a = marker("epubcfi(/6/2!/4/2/1:0)"), b = marker("epubcfi(/6/4!/4/2/1:0)")
        await store.set(a, bookID: "a/b")
        await store.set(b, bookID: "a_b")
        #expect(await store.marker(bookID: "a/b") == a)
        #expect(await store.marker(bookID: "a_b") == b)
        #expect(await store.marker(bookID: "../a") == nil)
    }

    @MainActor
    @Test func removingABookDeletesItsMarker() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(Book(
            id: "book", title: "T", author: "A", fileName: "book.epub", hasCover: false, addedAt: Date(),
            lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil))
        await library.markers.set(marker("epubcfi(/6/8!/4/2/1:0)"), bookID: "book")
        library.remove(id: "book")
        await library.removed()
        #expect(await library.markers.marker(bookID: "book") == nil)
    }
}
