import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Marking a page in the window, finding it again, and being told of it on reopening.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct MarkerWindowTests {
    private func reader(in folder: URL) -> ReaderWindowController {
        ReaderWindowController(
            positions: PositionStore(directory: folder.appendingPathComponent("Positions")),
            library: LibraryStore(directory: folder))
    }

    @Test func toggleMarksThenUnmarks() async throws {
        let saved = UserDefaults.standard.data(forKey: ReaderSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = reader(in: folder)
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        await reader.settled()
        #expect(reader.marker == nil)
        #expect(!reader.isRibbonShown)

        reader.perform(.toggleMarker)
        await reader.settled()
        let marker = try #require(reader.marker)
        #expect(marker.page == reader.location?.page)
        #expect(reader.location?.isMarked == true)
        #expect(reader.isRibbonShown)

        reader.perform(.toggleMarker)
        await reader.settled()
        #expect(reader.marker == nil)
        #expect(reader.location?.isMarked == false)
        #expect(!reader.isRibbonShown)
    }

    @Test func goToMarkerComesBackAndReopeningOffersIt() async throws {
        let saved = UserDefaults.standard.data(forKey: ReaderSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try fixture("long.epub")
        do {
            let reader = reader(in: folder)
            defer { reader.window?.close() }
            await reader.open(url, at: nil)
            await reader.settled()
            reader.perform(.toggleMarker)
            await reader.settled()
            let markedPage = try #require(reader.marker).page

            for _ in 0..<3 { reader.turn(.forward) }
            await reader.placesKept()
            #expect(reader.location?.isMarked == false)
            #expect(!reader.isRibbonShown)

            reader.perform(.goToMarker)
            await reader.settled()
            #expect(reader.location?.page == markedPage)
            #expect(reader.location?.isMarked == true)
            #expect(reader.isRibbonShown)

            // Left somewhere else.
            for _ in 0..<3 { reader.turn(.forward) }
            await reader.placesKept()
        }

        let again = reader(in: folder)
        defer { again.window?.close() }
        await again.open(url, at: nil)
        await again.settled()
        #expect(again.location?.isMarked == false)
        #expect(again.marker != nil)
        #expect(again.noticeText.contains("Marker on page"))
    }
}
