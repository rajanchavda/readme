import AppKit
import Foundation
import Testing
@testable import Readme

/// Turning pages past the line finishes a book in the window; jumping there doesn't.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct FinishWindowTests {
    private final class Record {
        var reads: [(location: ReaderLocation, finishing: Bool)] = []
    }

    private func opened(in folder: URL) async throws -> (ReaderWindowController, Record) {
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions"))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let reader = ReaderWindowController(positions: positions, library: library)
        let record = Record()
        reader.onRead = { _, location, finishing in record.reads.append((location, finishing)) }
        await reader.open(book)
        await reader.settled()
        return (reader, record)
    }

    @Test func turningPastTheLineFinishes() async throws {
        let saved = ReaderSettings.store.data(forKey: ReaderSettings.key)
        defer { ReaderSettings.store.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (reader, record) = try await opened(in: folder)
        defer { reader.window?.close() }
        let count = try #require(reader.location).pageCount
        #expect(reader.goToPage(typed: String(Int(Double(count) * 0.9))))
        await reader.settled()
        let before = try #require(reader.location)
        #expect(before.fraction < FinishRule.threshold)
        record.reads = []
        for _ in 0..<60 {
            guard let here = reader.location, here.fraction < FinishRule.threshold, !here.isAtEnd else { break }
            reader.turn(.forward)
            await reader.placesKept()
        }
        #expect(record.reads.contains { $0.finishing })
    }

    @Test func jumpingToTheEndDoesNot() async throws {
        let saved = ReaderSettings.store.data(forKey: ReaderSettings.key)
        defer { ReaderSettings.store.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (reader, record) = try await opened(in: folder)
        defer { reader.window?.close() }
        record.reads = []
        reader.perform(.goToEnd)
        await reader.settled()
        await reader.placesKept()
        #expect(reader.location?.isAtEnd == true)
        #expect(!record.reads.isEmpty)
        #expect(record.reads.allSatisfy { !$0.finishing })
    }
}
