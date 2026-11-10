import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Searching the book's text from the page: what's found, where it is, and what it leaves behind.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct SearchBridgeTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    @discardableResult
    private func open(_ name: String) async throws -> ReaderLocation {
        var settings = ReaderSettings()
        settings.fontSize = 18
        await view.applyStyles(css: ReadingCSS.css(settings, theme: .paper, fullscreen: false), columns: 2)
        return try await view.open(fixture(name), at: nil)
    }

    @Test func findsEveryMatchInTheReadableBook() async throws {
        try await open("search.epub")
        let outcome = try #require(await view.search("elena", limit: 500))
        #expect(outcome.matches.count == 3)
        #expect(outcome.matches.map(\.chapter) == ["The Harbour", "The Harbour", "The Letter"])
        #expect(outcome.matches.allSatisfy { $0.match.lowercased() == "elena" })
        #expect(outcome.matches.allSatisfy { !$0.pre.isEmpty || !$0.post.isEmpty })
        #expect(outcome.matches.map(\.page) == outcome.matches.map(\.page).sorted())
        #expect(!outcome.isCapped)
    }

    @Test func ignoresCaseAndAccents() async throws {
        try await open("search.epub")
        #expect(await view.search("CAFE", limit: 500)?.matches.map(\.match) == ["Café"])
    }

    @Test func skipsNonLinearSections() async throws {
        try await open("search.epub")
        #expect(await view.search("zanzibar", limit: 500)?.matches.isEmpty == true)
    }

    @Test func stopsAtTheLimit() async throws {
        try await open("long.epub")
        let outcome = try #require(await view.search("the", limit: 500))
        #expect(outcome.matches.count == 500)
        #expect(outcome.isCapped)
    }

    @Test func aNewerSearchCancelsTheOlder() async throws {
        try await open("long.epub")
        let view = view
        let older = Task { await view.search("the", limit: 100_000) }
        try await Task.sleep(for: .milliseconds(20))
        let newer = await view.search("harbour", limit: 500)
        #expect(await older.value == nil)
        #expect(newer?.matches.isEmpty == false)
    }

    @Test func aMatchsPageIsWhereGoingToItLands() async throws {
        try await open("long.epub")
        let match = try #require(await view.search("harbour", limit: 500)?.matches.dropFirst(40).first)
        let landed = try #require(await view.go(toCFI: match.cfi))
        #expect(landed.page <= match.page)
        #expect(match.page - landed.page <= 3)
    }

    @Test func searchingNeverMoves() async throws {
        let before = try await open("long.epub")
        _ = await view.search("harbour", limit: 500)
        #expect(view.currentLocation == before)
    }

    @Test func flashFadesAndLeavesNoHighlight() async throws {
        try await open("search.epub")
        let match = try #require(await view.search("elena", limit: 500)?.matches.first)
        _ = await view.go(toCFI: match.cfi)
        await view.flash(match.cfi)
        #expect(try await view.call("return readmeBridge.flashing()", as: String.self) == match.cfi)
        try await Task.sleep(for: .milliseconds(2500))
        #expect(try await view.call("return readmeBridge.flashing()", as: String.self) == nil)
        #expect(view.highlightCFIs.isEmpty)
    }
}
