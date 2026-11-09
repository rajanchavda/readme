import Foundation
import Testing
@testable import Readme

private func mark(_ cfi: String, fraction: Double, text: String = "some words") -> Highlight {
    Highlight(cfi: cfi, text: text, chapterTitle: "Chapter 1", fraction: fraction)
}

@Suite struct HighlightStoreTests {
    @Test func roundTripInReadingOrder() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        #expect(await store.highlights(bookID: "book").isEmpty)
        let late = mark("epubcfi(/6/8!/4,/1:0,/1:4)", fraction: 0.6)
        let early = mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1)
        await store.add(late, bookID: "book")
        await store.add(early, bookID: "book")
        #expect(await store.highlights(bookID: "book").map(\.cfi) == [early.cfi, late.cfi])
        #expect(await store.highlights(bookID: "other").isEmpty)
    }

    @Test func survivesRestart() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1)
        await HighlightStore(directory: folder).add(one, bookID: "book")
        let loaded = await HighlightStore(directory: folder).highlights(bookID: "book")
        #expect(loaded.map(\.id) == [one.id])
        #expect(loaded.first?.text == "some words")
    }

    @Test func samePassageIsKeptOnce() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        await store.add(mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1), bookID: "book")
        await store.add(mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1), bookID: "book")
        #expect(await store.highlights(bookID: "book").count == 1)
    }

    @Test func removeTakesOutOne() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        let one = mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1)
        let two = mark("epubcfi(/6/4!/4,/1:0,/1:4)", fraction: 0.2)
        await store.add(one, bookID: "book")
        await store.add(two, bookID: "book")
        await store.remove(id: one.id, bookID: "book")
        #expect(await store.highlights(bookID: "book").map(\.id) == [two.id])
    }

    @Test func removeBookDeletesItsFile() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        await store.add(mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1), bookID: "book")
        await store.remove(bookID: "book")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func corruptFileIsIgnored() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        await store.add(mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1), bookID: "book")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try Data("not json".utf8).write(to: file)
        }
        #expect(await store.highlights(bookID: "book").isEmpty)
    }

    @MainActor
    @Test func removingABookDeletesItsHighlights() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(Book(
            id: "book", title: "T", author: "A", fileName: "book.epub", hasCover: false, addedAt: Date(),
            lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil))
        await library.highlights.add(mark("epubcfi(/6/2!/4,/1:0,/1:4)", fraction: 0.1), bookID: "book")
        library.remove(id: "book")
        await library.removed()
        #expect(await library.highlights.highlights(bookID: "book").isEmpty)
    }

    @MainActor
    @Test func barStaysInsideAndAboveTheWords() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let above = HighlightBar.frame(for: CGRect(x: 400, y: 300, width: 100, height: 20), in: bounds)
        #expect(above.minY > 320)
        #expect(abs(above.midX - 450) < 1)
        let nearEdge = HighlightBar.frame(for: CGRect(x: 0, y: 300, width: 10, height: 20), in: bounds)
        #expect(nearEdge.minX >= 0)
        let nearTop = HighlightBar.frame(for: CGRect(x: 400, y: 660, width: 100, height: 20), in: bounds)
        #expect(nearTop.maxY <= 700)
        #expect(nearTop.maxY <= 660)
    }
}
