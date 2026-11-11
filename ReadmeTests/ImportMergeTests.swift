import Foundation
import Testing
@testable import Readme

private func mark(_ cfi: String, id: UUID = UUID(), fraction: Double = 0.1) -> Highlight {
    Highlight(id: id, cfi: cfi, text: "words", chapterTitle: nil, fraction: fraction, created: bundleDate(10))
}

/// What importing a bundle adds to the stores, without touching what's already there.
@Suite struct ImportMergeTests {
    @Test func mergeAddsOnlyWhatsNew() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HighlightStore(directory: folder)
        let a = mark("epubcfi(/6/2!/4,/1:0,/1:4)")
        await store.add(a, bookID: "book")
        // Same id as A but another passage, and A's passage under another id: both already here.
        let sameID = mark("epubcfi(/6/8!/4,/1:0,/1:4)", id: a.id, fraction: 0.5)
        let samePassage = mark(a.cfi)
        let new = mark("epubcfi(/6/4!/4,/1:0,/1:4)", fraction: 0.3)
        #expect(await store.merge([a, sameID, samePassage, new], bookID: "book") == 1)
        #expect(await store.highlights(bookID: "book") == [a, new])
    }

    @Test func setIfNoneKeepsAnExistingMarker() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        let one = Marker(cfi: "epubcfi(/6/2!/4/2/1:0)", fraction: 0.1, page: 3)
        let two = Marker(cfi: "epubcfi(/6/8!/4/2/1:0)", fraction: 0.6, page: 30)
        await store.set(one, bookID: "book")
        #expect(await store.setIfNone(two, bookID: "book") == false)
        #expect(await store.marker(bookID: "book") == one)
    }

    @Test func setIfNoneSetsWhenThereIsNone() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MarkerStore(directory: folder)
        let two = Marker(cfi: "epubcfi(/6/8!/4/2/1:0)", fraction: 0.6, page: 30)
        #expect(await store.setIfNone(two, bookID: "book"))
        #expect(await store.marker(bookID: "book") == two)
    }

    @Test func furtherIsByFraction() {
        #expect(ImportMerge.isFurther(bundlePlace(0.6), than: bundlePlace(0.4)))
        #expect(!ImportMerge.isFurther(bundlePlace(0.4), than: bundlePlace(0.4)))
        #expect(!ImportMerge.isFurther(bundlePlace(0.2), than: bundlePlace(0.4)))
        #expect(ImportMerge.isFurther(bundlePlace(0.1), than: nil))
    }

    @MainActor
    @Test func applyImportedKeepsTheLaterReadDate() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder, now: { bundleDate(200) })
        store.add(Book(id: "a", title: "A", author: nil, fileName: "a.epub", hasCover: false, addedAt: bundleDate(1)))
        store.markRead(id: "a", location: bundlePlace(0.3))
        store.applyImported(id: "a", addedAt: nil, lastReadAt: bundleDate(100), location: nil)
        #expect(store.book(id: "a")?.lastReadAt == bundleDate(200))
        store.applyImported(id: "a", addedAt: nil, lastReadAt: bundleDate(300), location: nil)
        #expect(store.book(id: "a")?.lastReadAt == bundleDate(300))
        #expect(store.book(id: "a")?.addedAt == bundleDate(1))
    }

    @MainActor
    @Test func applyImportedSetsAddedAtAndChapter() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(directory: folder)
        store.add(Book(id: "a", title: "A", author: nil, fileName: "a.epub", hasCover: false, addedAt: bundleDate(1)))
        store.applyImported(id: "a", addedAt: bundleDate(50), lastReadAt: bundleDate(60), location: bundlePlace(0.5, chapter: "Two"))
        let book = try #require(store.book(id: "a"))
        #expect(book.addedAt == bundleDate(50))
        #expect(book.lastReadAt == bundleDate(60))
        #expect(book.chapterTitle == "Two")
        #expect(book.chapterMinutesLeft == 3)
        store.applyImported(id: "missing", addedAt: bundleDate(1), lastReadAt: nil, location: nil)
        #expect(store.books.count == 1)
    }
}
