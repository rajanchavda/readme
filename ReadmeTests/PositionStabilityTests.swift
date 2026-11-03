import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Settings of its own, so the tests leave the reader's alone.
private func scratchDefaults() -> UserDefaults {
    let name = "PositionStabilityTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// The reading window keeps its place through every change to the look, and remembers it between
/// openings. The place is the start of the spread: its first visible text is the marker that has to
/// stay in view.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct PositionStabilityTests {
    static let wide = NSSize(width: 1048, height: 620)

    // MARK: Layout changes

    @Test func biggerText() async throws {
        let (reader, _) = try await openReader()
        defer { reader.window?.close() }
        let marker = try await markerHalfway(reader)
        #expect(reader.layoutColumns == 2)
        reader.change(settings { $0.fontSize = 26 })
        try await expectShown(marker, reader)
        #expect(reader.layoutColumns == 1)
    }

    @Test func widerLines() async throws {
        let (reader, _) = try await openReader()
        defer { reader.window?.close() }
        let marker = try await markerHalfway(reader)
        reader.change(settings { $0.lineWidth = .wide })
        try await expectShown(marker, reader)
    }

    @Test func oneColumnToTwo() async throws {
        let (reader, _) = try await openReader(size: NSSize(width: 700, height: 620))
        defer { reader.window?.close() }
        #expect(reader.layoutColumns == 1)
        let marker = try await markerHalfway(reader)
        reader.window?.setContentSize(Self.wide)
        try await expectShown(marker, reader)
        #expect(reader.layoutColumns == 2)
    }

    @Test func windowResize() async throws {
        let (reader, _) = try await openReader()
        defer { reader.window?.close() }
        let marker = try await markerHalfway(reader)
        reader.window?.setContentSize(NSSize(width: 1048, height: 820))
        try await expectShown(marker, reader)
    }

    /// Each change goes back to where the reader was, not where the last change left the book, so
    /// changes made one after another don't creep away from it. Each going back can land on a page
    /// that starts before the place, which is fine once but not over and over, so the test needs
    /// places where that page break falls differently.
    @Test(arguments: [0.5, 1.0 / 31, 14.0 / 31, 18.0 / 31])
    func changesThereAndBack(at fraction: Double) async throws {
        let (reader, _) = try await openReader()
        defer { reader.window?.close() }
        let marker = try await marker(at: fraction, reader)
        for size in [26.0, 32, 18] {
            reader.change(settings { $0.fontSize = size })
            try await expectShown(marker, reader)
        }
        reader.change(settings { $0.lineWidth = .narrow })
        try await expectShown(marker, reader)
        reader.change(settings { $0.lineWidth = .regular })
        try await expectShown(marker, reader)
        reader.window?.setContentSize(NSSize(width: 700, height: 620))
        try await expectShown(marker, reader)
        reader.window?.setContentSize(Self.wide)
        try await expectShown(marker, reader)
    }

    /// The first text the reader saw starts the page they're shown, not part-way down it.
    @Test func biggerTextStartsAtThePlace() async throws {
        let (reader, _) = try await openReader()
        defer { reader.window?.close() }
        let marker = try await markerHalfway(reader)
        reader.change(settings { $0.fontSize = 26 })
        let shown = try await expectShown(marker, reader)
        // One page of 26 pt text holds well under a thousand characters.
        #expect(shown.textBefore < 1000)
    }

    // MARK: Remembering

    @Test func reopensWhereItWasLeft() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let (reader, _) = try await openReader(store: store)
        let marker = try await markerHalfway(reader)
        await reader.keepPlace()
        reader.window?.close()

        let (again, _) = try await openReader(store: PositionStore(directory: folder))
        defer { again.window?.close() }
        try await expectShown(marker, again)
    }

    /// A change of look shows the same place, which is what's already saved.
    @Test func aLayoutChangeSavesNothingNew() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let (reader, id) = try await openReader(store: store)
        defer { reader.window?.close() }
        _ = try await markerHalfway(reader)
        await reader.keepPlace()
        let saved = try #require(await store.location(bookID: id))
        reader.change(settings { $0.fontSize = 26 })
        try await settle(reader)
        reader.window?.setContentSize(NSSize(width: 1048, height: 800))
        try await settle(reader)
        await reader.keepPlace()
        #expect(await store.location(bookID: id)?.cfi == saved.cfi)
    }

    /// Opening a book again and again doesn't move it.
    @Test func reopeningDoesNotCreep() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let (reader, id) = try await openReader(store: store)
        let marker = try await markerHalfway(reader)
        await reader.keepPlace()
        let saved = try #require(await store.location(bookID: id))
        reader.window?.close()
        for size in [26.0, 18] {
            let (again, _) = try await openReader(store: store, fontSize: size)
            try await expectShown(marker, again)
            await again.keepPlace()
            again.window?.close()
        }
        #expect(await store.location(bookID: id)?.cfi == saved.cfi)
    }

    /// A turn the reader asks for and closes the window on, before its curl or its move is over, is
    /// still saved by the time quitting would go ahead.
    @Test(arguments: [1, 3])
    func aTurnStillLandingIsSaved(turns count: Int) async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let (reader, id) = try await openReader(store: store)
        _ = try await markerHalfway(reader)
        await reader.keepPlace()
        let before = try #require(reader.location)
        for _ in 0..<count { reader.turn(.forward) }
        reader.window?.close()
        await reader.keepPlace()
        let saved = try #require(await store.location(bookID: id))
        #expect(saved.page > before.page)
        #expect(saved.cfi == reader.location?.cfi)
    }

    /// A link in the book is a move of the reader's, so a restyle under way doesn't take them back.
    @Test func aLinkFollowedDuringARestyleIsKept() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let (reader, id) = try await openReader(store: store)
        defer { reader.window?.close() }
        _ = try await markerHalfway(reader)
        let book = try #require(reader.book)
        reader.change(settings { $0.fontSize = 26 })
        _ = try await book.call(
            """
            const doc = readmeBridge.currentDocument()
            const link = doc.createElement('a')
            link.setAttribute('href', 'ch20.xhtml')
            link.style.display = 'none'
            doc.body.append(link)
            link.click()
            link.remove()
            """, as: Bool.self)
        try await settle(reader)
        try await Task.sleep(for: .milliseconds(300))
        try await settle(reader)
        #expect(reader.location?.chapterTitle == "Chapter 20")
        await reader.keepPlace()
        #expect(await store.location(bookID: id)?.chapterTitle == "Chapter 20")
    }

    @Test func aPlaceThatNoLongerResolvesOpensNearestIt() async throws {
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PositionStore(directory: folder)
        let id = try await BookID.of(fixture("long.epub"))
        for cfi in [
            "epubcfi(/6/999!/4/2,/1:0,/1:10)", "epubcfi(/6/14!/4/900/3:7)", "epubcfi(/6/14!/4/2/1:99999)",
            "not a cfi", "",
        ] {
            let lost = ReaderLocation(
                cfi: cfi, fraction: 0.5, chapterTitle: nil, chapterMinutesLeft: 0,
                isAtStart: false, isAtEnd: false, page: 1, pageCount: 1)
            await store.save(lost, bookID: id)
            let (reader, _) = try await openReader(store: store)
            defer { reader.window?.close() }
            let opened = try #require(reader.location, "\(cfi)")
            #expect(opened.fraction < 0.5, "\(cfi)")
            // Where it opened replaces the place that's gone.
            await reader.keepPlace()
            let saved = await store.location(bookID: id)?.cfi
            #expect(saved == opened.cfi || saved == cfi && !opened.isAtStart, "\(cfi): saved \(saved ?? "-")")
            if cfi.isEmpty || cfi == "not a cfi" || cfi.contains("999!") { #expect(saved == opened.cfi, "\(cfi)") }
            // The book still works: its look can change, which keeps it where it opened, and its
            // pages turn.
            reader.change(settings { $0.fontSize = 26 })
            try await settle(reader)
            let restyled = try #require(reader.location, "\(cfi)")
            #expect(abs(restyled.fraction - opened.fraction) < 0.02, "\(cfi): \(opened.fraction) to \(restyled.fraction)")
            #expect(await reader.book?.next() != nil, "\(cfi)")
        }
    }

    // MARK: Helpers

    private let defaults = scratchDefaults()

    private func settings(_ change: (inout ReaderSettings) -> Void) -> ReaderSettings {
        var settings = ReaderSettings.load(defaults)
        change(&settings)
        return settings
    }

    /// A reading window on screen at `size`, with `long.epub` open where `store` says, and its ID.
    private func openReader(
        size: NSSize = wide, store: PositionStore? = nil, fontSize: Double = 18
    ) async throws -> (ReaderWindowController, String) {
        var start = ReaderSettings()
        start.fontSize = fontSize
        start.save(defaults)
        let reader = ReaderWindowController(defaults: defaults, positions: store)
        // Its size is the test's, and isn't kept for the app.
        reader.window?.setFrameAutosaveName("")
        reader.window?.setContentSize(size)
        reader.window?.orderFrontRegardless()
        let url = try fixture("long.epub")
        await reader.open(url)
        try await settle(reader)
        #expect(reader.location != nil)
        return (reader, try await BookID.of(url))
    }

    /// Goes halfway through the book and returns the start of the text on the spread.
    private func markerHalfway(_ reader: ReaderWindowController) async throws -> Marker {
        try await marker(at: 0.5, reader)
    }

    private func marker(at fraction: Double, _ reader: ReaderWindowController) async throws -> Marker {
        let book = try #require(reader.book)
        _ = try #require(await book.go(toFraction: fraction))
        await book.settle()
        let here = try #require(book.currentLocation)
        let shown = try await shown(Marker(cfi: here.cfi, text: ""), reader)
        try #require(shown.isOnSpread && shown.textBefore == 0, "\(shown)")
        return Marker(cfi: here.cfi, text: String(shown.text.prefix(40)))
    }

    private func settle(_ reader: ReaderWindowController) async throws {
        await reader.settled()
        await reader.book?.settle()
    }

    @discardableResult
    private func expectShown(
        _ marker: Marker, _ reader: ReaderWindowController, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Shown {
        try await settle(reader)
        let shown = try await shown(marker, reader)
        #expect(
            shown.isOnSpread, "\(marker.text) not on: \(shown.text.prefix(300))…", sourceLocation: sourceLocation)
        return shown
    }

    /// Whether the start of `marker` is on the visible spread, as foliate measures it, and how much
    /// of the spread's text comes before it.
    private func shown(_ marker: Marker, _ reader: ReaderWindowController) async throws -> Shown {
        let book = try #require(reader.book)
        return try #require(try await book.call(
            """
            const view = document.querySelector('foliate-view')
            const spread = view.lastLocation?.range
            const { doc, index } = view.renderer.getContents()[0]
            const text = spread?.toString().split(/\\s+/).filter(Boolean).join(' ') ?? ''
            const target = view.resolveNavigation(cfi)
            if (!spread || target?.index !== index) return { isOnSpread: false, textBefore: -1, text }
            const place = target.anchor(doc)
            const { startContainer: node, startOffset: offset } = place
            const atEnd = node === spread.endContainer && offset === spread.endOffset
            const isOnSpread = spread.comparePoint(node, offset) === 0 && !atEnd
            const before = doc.createRange()
            before.setStart(spread.startContainer, spread.startOffset)
            if (isOnSpread) before.setEnd(node, offset)
            const textBefore = isOnSpread ? before.toString().split(/\\s+/).filter(Boolean).join(' ').length : -1
            return { isOnSpread, textBefore, text }
            """, arguments: ["cfi": marker.cfi], as: Shown.self))
    }
}

/// The start of the spread the reader was on, and the text there.
private struct Marker {
    var cfi: String
    var text: String
}

private struct Shown: Decodable, Sendable {
    var isOnSpread: Bool
    var textBefore: Int
    var text: String
}
