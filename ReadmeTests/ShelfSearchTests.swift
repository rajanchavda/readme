import AppKit
import SwiftUI
import Testing
@testable import Readme

private func book(_ id: String, _ title: String, by author: String? = nil) -> Book {
    Book(
        id: id, title: title, author: author, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: 0), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

@Suite struct ShelfSearchTests {
    @Test func matchesTitleIgnoringCaseAndAccents() {
        let miserables = book("a", "Les Misérables")
        #expect(ShelfSearch.matches(miserables, query: "miserables"))
        #expect(ShelfSearch.matches(miserables, query: "MISÉR"))
        #expect(ShelfSearch.matches(miserables, query: "les mis"))
    }

    @Test func matchesAuthor() {
        #expect(ShelfSearch.matches(book("a", "Anna Karenina", by: "Leo Tolstoy"), query: "tolstoy"))
    }

    @Test func everyWordMustMatch() {
        let dune = book("a", "Dune", by: "Frank Herbert")
        #expect(ShelfSearch.matches(dune, query: "dune herbert"))
        #expect(!ShelfSearch.matches(dune, query: "dune asimov"))
    }

    @Test func noAuthorMatchesOnTitle() {
        let emma = book("a", "Emma")
        #expect(ShelfSearch.matches(emma, query: "emm"))
        #expect(!ShelfSearch.matches(emma, query: "austen"))
    }

    @Test func blankQueryMatchesEverything() {
        let books = [book("b", "Emma"), book("a", "Dune")]
        #expect(ShelfSearch.filter(books, query: "   ").map(\.id) == ["b", "a"])
    }

    @Test func filterKeepsOrder() {
        let books = [book("c", "Dune"), book("a", "Dune Messiah"), book("b", "Emma")]
        #expect(ShelfSearch.filter(books, query: "dune").map(\.id) == ["c", "a"])
    }

    @MainActor @Test func closeClearsAndFolds() {
        let search = ShelfSearch()
        search.open()
        #expect(search.isOpen)
        #expect(search.focusRequest == 1)
        search.query = "x"
        search.close()
        #expect(search.query == "")
        #expect(!search.isOpen)
    }

    @MainActor @Test func isActiveIgnoresWhitespace() {
        let search = ShelfSearch()
        search.query = "  "
        #expect(!search.isActive)
        search.query = " a "
        #expect(search.isActive)
    }

    @MainActor @Test func escapeClosesOpenSearchFirst() {
        let search = ShelfSearch()
        search.open()
        search.query = "a"
        var fellThrough = 0
        ShelfSearch.escape(search) { fellThrough += 1 }
        #expect(!search.isOpen)
        #expect(search.query == "")
        #expect(fellThrough == 0)
        ShelfSearch.escape(search) { fellThrough += 1 }
        #expect(fellThrough == 1)
    }

    /// Opening the field, as a click on the magnifier or ⌘F does, puts the keyboard in it.
    @MainActor @Test func openingPutsTheKeyboardInTheField() async throws {
        let search = ShelfSearch()
        let host = NSHostingView(rootView: ShelfSearchField(search: search) {})
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        search.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(search.isOpen)
        #expect(window.firstResponder is NSText)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: host) == true)
    }

    /// A click on the magnifier opens the field with the keyboard in it.
    @MainActor @Test func clickingTheMagnifierPutsTheKeyboardInTheField() async throws {
        let search = ShelfSearch()
        let host = NSHostingView(rootView: ShelfSearchField(search: search) {})
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))

        let centre = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(centre, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(search.isOpen)
        #expect(window.firstResponder is NSText)
    }
}
