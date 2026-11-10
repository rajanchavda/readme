import Foundation
import Testing
@testable import Readme

/// A new, empty folder for one test's positions.
func positionsFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("PositionStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private let here = ReaderLocation(
    cfi: "epubcfi(/6/14!/4/2/10,/1:12,/3:40)", fraction: 0.42, chapterTitle: "Chapter 7",
    chapterMinutesLeft: 6.5, isAtStart: false, isAtEnd: false, page: 210, pageCount: 500)

@Suite struct PositionStoreTests {
    @Test func roundTrip() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        #expect(await store.location(bookID: "book") == nil)
        await store.save(here, bookID: "book")
        #expect(await store.location(bookID: "book") == here)
        #expect(await store.location(bookID: "other") == nil)
    }

    @Test func survivesRestart() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        await PositionStore(directory: folder).save(here, bookID: "book")
        #expect(await PositionStore(directory: folder).location(bookID: "book") == here)
    }

    @Test func corruptFileIsIgnored() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        await store.save(here, bookID: "book")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        try Data("{ not a place".utf8).write(to: file)
        #expect(await store.location(bookID: "book") == nil)
        #expect(await PositionStore(directory: folder).location(bookID: "book") == nil)
    }

    /// Places saved before the reading marker existed have no `isMarked`, and still load.
    @Test func placeSavedWithoutMarkedFlagLoads() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        await store.save(here, bookID: "book")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["isMarked"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let loaded = await store.location(bookID: "book")
        #expect(loaded == here)
        #expect(loaded?.isMarked == false)
    }

    @Test func theLatestSaveWins() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        var later = here
        later.cfi = "epubcfi(/6/16!/4/2,/1:0,/1:80)"
        later.page = 230
        await store.save(here, bookID: "book")
        await store.save(later, bookID: "book")
        #expect(await PositionStore(directory: folder).location(bookID: "book") == later)
    }

    @Test func removeForgetsTheBook() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        await store.save(here, bookID: "book")
        await store.save(here, bookID: "other")
        await store.remove(bookID: "book")
        #expect(await store.location(bookID: "book") == nil)
        #expect(await store.location(bookID: "other") == here)
        // Removing a book with nothing saved is fine.
        await store.remove(bookID: "never")
    }

    /// A folder that doesn't exist yet is made on the first save.
    @Test func makesItsFolder() async throws {
        let parent = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Positions", isDirectory: true)
        await PositionStore(directory: folder).save(here, bookID: "book")
        #expect(await PositionStore(directory: folder).location(bookID: "book") == here)
    }

    /// A book's ID is its file's name in the folder, so one that isn't a plain name is still kept apart.
    @Test func oddBookIDsStayInTheFolder() async throws {
        let parent = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appendingPathComponent("Positions", isDirectory: true)
        let store = PositionStore(directory: folder)
        await store.save(here, bookID: "../escape")
        #expect(await store.location(bookID: "../escape") == here)
        let outside = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(outside == ["Positions"])
    }

    @Test func aBookIDIsTheSameForTheSameFile() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try #require(Bundle(for: PositionStoreToken.self).url(forResource: "Fixtures", withExtension: nil))
        let book = root.appendingPathComponent("long.epub")
        let copy = folder.appendingPathComponent("renamed.epub")
        try FileManager.default.copyItem(at: book, to: copy)
        let id = try await BookID.of(book)
        #expect(try await BookID.of(copy) == id)
        #expect(try await BookID.of(root.appendingPathComponent("no-toc.epub")) != id)
        #expect(id.count == 64)
    }
}

private final class PositionStoreToken {}

@MainActor
@Suite struct PlaceWriterTests {
    /// Places for two books given one after the other, faster than they're written, are both kept.
    @Test func eachBookKeepsItsNewestPlace() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let writer = PlaceWriter(store: store)
        var later = here
        later.cfi = "epubcfi(/6/16!/4/2,/1:0,/1:80)"
        var other = here
        other.cfi = "epubcfi(/6/4!/4/2,/1:0,/1:20)"
        writer.save(here, bookID: "a")
        writer.save(other, bookID: "b")
        writer.save(later, bookID: "a")
        await writer.written()
        #expect(await store.location(bookID: "a") == later)
        #expect(await store.location(bookID: "b") == other)
    }
}
