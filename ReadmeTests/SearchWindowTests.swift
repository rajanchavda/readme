import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Searching from the reading window: the floating box, picking a match, and what's kept.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct SearchWindowTests {
    private func reader(in folder: URL) -> ReaderWindowController {
        ReaderWindowController(
            positions: PositionStore(directory: folder.appendingPathComponent("Positions")),
            library: LibraryStore(directory: folder))
    }

    /// Runs `body` with a reader open on `name`, keeping the reader's settings as they were.
    private func withReader(
        _ name: String, _ body: @MainActor (ReaderWindowController, URL) async throws -> Void
    ) async throws {
        let saved = UserDefaults.standard.data(forKey: ReaderSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = reader(in: folder)
        defer { reader.window?.close() }
        await reader.open(try fixture(name), at: nil)
        await reader.settled()
        try await body(reader, folder)
    }

    @Test func findOpensTheBoxAndSearchListsMatches() async throws {
        try await withReader("search.epub") { reader, _ in
            #expect(!reader.isSearchShown)
            reader.perform(.find)
            #expect(reader.isSearchShown)
            await reader.search("elena")
            #expect(reader.searchOutcome?.matches.count == 3)
        }
    }

    @Test func pickingAMatchMovesTheSavedPlace() async throws {
        let url = try fixture("long.epub")
        try await withReader("long.epub") { reader, folder in
            reader.perform(.find)
            await reader.search("harbour")
            let match = try #require(reader.searchOutcome?.matches.dropFirst(40).first)
            reader.pickSearchMatch(at: 40)
            await reader.settled()
            #expect(!reader.isSearchShown)
            let landed = try #require(reader.location)
            #expect(landed.page <= match.page)
            #expect(match.page - landed.page <= 3)
            await reader.placesKept()

            let again = self.reader(in: folder)
            defer { again.window?.close() }
            await again.open(url, at: nil)
            await again.settled()
            #expect(again.location?.page == landed.page)
        }
    }

    @Test func findAgainKeepsTheLastSearch() async throws {
        try await withReader("search.epub") { reader, _ in
            reader.perform(.find)
            await reader.search("elena")
            let found = reader.searchOutcome
            reader.pickSearchMatch(at: 1)
            await reader.settled()
            reader.perform(.find)
            #expect(reader.isSearchShown)
            #expect(reader.searchQuery == "elena")
            #expect(reader.searchOutcome == found)
            #expect(reader.searchSelection == 1)
        }
    }

    @Test func escapeClosesWithoutMoving() async throws {
        try await withReader("long.epub") { reader, _ in
            let before = reader.location
            reader.perform(.find)
            await reader.search("harbour")
            reader.closeSearch()
            await reader.settled()
            #expect(!reader.isSearchShown)
            #expect(reader.location == before)
        }
    }

    @Test func searchNeverTouchesTheMarker() async throws {
        try await withReader("long.epub") { reader, _ in
            reader.perform(.toggleMarker)
            await reader.settled()
            let marker = try #require(reader.marker)
            reader.perform(.find)
            await reader.search("harbour")
            reader.pickSearchMatch(at: 60)
            await reader.settled()
            #expect(reader.marker == marker)
        }
    }

    @Test func oneLetterSearchesNothing() async throws {
        try await withReader("search.epub") { reader, _ in
            reader.perform(.find)
            await reader.search("e")
            #expect(reader.searchOutcome == nil)
        }
    }

    @Test func aStaleReplyIsDropped() async throws {
        try await withReader("long.epub") { reader, _ in
            reader.perform(.find)
            let older = Task { await reader.search("the") }
            // Once the older search is under way, a newer one replaces it.
            while reader.searchQuery != "the" { await Task.yield() }
            await reader.search("harbour")
            await older.value
            #expect(reader.searchQuery == "harbour")
            #expect(reader.searchOutcome?.matches.allSatisfy { $0.match.lowercased() == "harbour" } == true)
        }
    }

    @Test func openingAnotherBookForgetsTheSearch() async throws {
        try await withReader("search.epub") { reader, _ in
            reader.perform(.find)
            await reader.search("elena")
            reader.closeSearch()
            await reader.open(try fixture("long.epub"), at: nil)
            await reader.settled()
            #expect(reader.searchQuery == "")
            #expect(reader.searchOutcome == nil)
            #expect(reader.searchSelection == nil)
        }
    }

    /// Scrolling over the open box scrolls its list, and scrolling or swiping beside it never turns the page.
    @Test func scrollingIsTheBoxsWhileItsOpen() async throws {
        try await withReader("search.epub") { reader, _ in
            let inside = NSPoint(x: reader.searchBoxFrame.midX, y: reader.searchBoxFrame.midY)
            #expect(reader.scrollPlace(at: inside) == .closed)
            reader.perform(.find)
            await reader.search("the")
            let frame = reader.searchBoxFrame
            #expect(reader.scrollPlace(at: NSPoint(x: frame.midX, y: frame.midY)) == .under)
            #expect(reader.scrollPlace(at: NSPoint(x: frame.minX - 40, y: frame.midY)) == .beside)
            reader.closeSearch()
            #expect(reader.scrollPlace(at: NSPoint(x: frame.midX, y: frame.midY)) == .closed)
        }
    }

    @Test func clickingARowGoesToIt() async throws {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let box = SearchBox(frame: NSRect(x: 40, y: 40, width: SearchBox.width, height: 300))
        window.contentView?.addSubview(box)
        let match = SearchMatch(cfi: "epubcfi(/6/2!/4/2,/1:0,/1:5)", pre: "the girl ", match: "Elena", post: " stood",
                                page: 3, chapter: "The Harbour")
        let outcome = SearchOutcome(matches: Array(repeating: match, count: 5), isCapped: false)
        box.setTheme(.paper)
        box.begin(query: "elena", outcome: outcome, selected: 0)
        box.frame.size.height = box.preferredHeight
        box.layoutSubtreeIfNeeded()

        var picked: Int?
        var closedFirst = false
        box.onPick = { picked = $0 }
        box.onClose = { if picked == nil { closedFirst = true } }
        let point = box.convert(box.rowCenter(2), to: nil)
        // What the window does with a click: find the view under it and hand it the click.
        let hit = try #require(window.contentView?.hitTest(window.contentView!.convert(point, from: nil)))
        #expect(String(describing: type(of: hit)) == "RowList")
        let typing = window.firstResponder
        #expect(typing is NSTextView)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        hit.mouseDown(with: event)
        #expect(window.firstResponder === typing)
        #expect(picked == 2)
        #expect(!closedFirst)
    }
}
