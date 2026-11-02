import AppKit
import Testing
@testable import Readme

/// How far through each chapter of the contents the reader is.
@Suite struct TOCProgressTests {
    private func entries(_ fractions: [Double]) -> [TOCEntry] {
        fractions.enumerated().map { TOCEntry(title: "Chapter \($0.offset + 1)", href: "ch\($0.offset + 1).xhtml", level: 0, fraction: $0.element) }
    }

    @Test func chaptersBeforeTheCurrentOneAreRead() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0.6) == [.read, .current, .unread])
    }

    @Test func theFirstChapterIsCurrentAtTheStart() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0) == [.current, .unread, .unread])
    }

    @Test func noEntriesHaveNoStates() {
        #expect(TOCProgress.states(entries: [], fraction: 0.4).isEmpty)
    }

    /// A spread starting where a chapter does can be reported a hair before it.
    @Test func aChapterStartingWhereTheSpreadDoesIsCurrent() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0.5 - 1e-12) == [.read, .current, .unread])
    }

    @Test func theLastChapterIsCurrentAtTheEnd() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 1) == [.read, .read, .current])
    }

    /// Before the first entry, on a cover, say, nothing has been read yet.
    @Test func beforeTheFirstEntryNothingIsCurrent() {
        #expect(TOCProgress.states(entries: entries([0.1, 0.5]), fraction: 0.02) == [.unread, .unread])
    }
}

/// An entry whose link leads nowhere has no place in the book, so it's never current.
@Suite struct TOCProgressDeadLinkTests {
    @Test func anEntryWithNoPlaceIsNeverCurrent() {
        let entries = [
            TOCEntry(title: "One", href: "a.xhtml", level: 0, fraction: 0),
            TOCEntry(title: "Lost", href: "missing.xhtml", level: 0, fraction: nil),
            TOCEntry(title: "Two", href: "b.xhtml", level: 0, fraction: 0.5),
        ]
        #expect(TOCProgress.states(entries: entries, fraction: 0.2) == [.current, .unread, .unread])
        #expect(TOCProgress.states(entries: entries, fraction: 0.6) == [.read, .read, .current])
    }
}

/// The sidebar's look: the chapter being read is marked by its dot and full ink alone, apart from the
/// keyboard's selection, and nothing takes the system's accent colour.
@MainActor
@Suite struct TOCSidebarTests {
    let window: NSWindow
    let sidebar: TOCSidebar
    let entries = [
        TOCEntry(title: "Chapter 1", href: "ch1.xhtml", level: 0, fraction: 0),
        TOCEntry(title: "Chapter 2", href: "ch2.xhtml", level: 0, fraction: 0.3),
        TOCEntry(title: "Lost", href: "missing.xhtml", level: 0, fraction: nil),
        TOCEntry(title: "Chapter 3", href: "ch3.xhtml", level: 0, fraction: 0.6),
    ]

    init() {
        let frame = NSRect(x: 0, y: 0, width: TOCSidebar.width, height: 400)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar = TOCSidebar(frame: frame)
        window.contentView = sidebar
    }

    @Test(arguments: [Theme.paper, .sepia, .night])
    func theCurrentMarkerStaysWhenTheSelectionMoves(_ theme: Theme) {
        sidebar.setTheme(theme)
        sidebar.show(entries, at: 0.4)
        #expect((0..<4).map { sidebar.isMarkedCurrent(row: $0) } == [false, true, false, false])
        sidebar.select(row: 3)
        #expect((0..<4).map { sidebar.isMarkedCurrent(row: $0) } == [false, true, false, false])
        sidebar.select(row: 0)
        #expect((0..<4).map { sidebar.isMarkedCurrent(row: $0) } == [false, true, false, false])
        #expect(sidebar.isRowSelected(0))
    }

    @Test(arguments: [Theme.paper, .sepia, .night])
    func everyColourIsTheThemesInk(_ theme: Theme) throws {
        sidebar.setTheme(theme)
        sidebar.show(entries, at: 0.4)
        window.makeFirstResponder(nil)
        sidebar.focus()
        let ink = try #require(ReadingCSS.colors(theme).ink.usingColorSpace(.sRGB))
        let accent = try #require(NSColor.controlAccentColor.usingColorSpace(.sRGB))
        var colours: [NSColor] = []
        for row in 0..<4 {
            sidebar.select(row: row)
            colours.append(try #require(sidebar.titleColor(row: row)))
            colours.append(sidebar.selectionColor)
        }
        for colour in colours {
            let colour = try #require(colour.usingColorSpace(.sRGB))
            #expect(!sameHue(colour, accent), "\(colour) is the accent colour")
            #expect(sameHue(colour, ink), "\(colour) isn't the theme's ink")
        }
        // Being read is in full ink, and read ones are dimmer than ones ahead.
        let current = try #require(sidebar.titleColor(row: 1)?.alphaComponent)
        let read = try #require(sidebar.titleColor(row: 0)?.alphaComponent)
        let ahead = try #require(sidebar.titleColor(row: 3)?.alphaComponent)
        #expect(current == 1)
        #expect(read < ahead && ahead < current)
        #expect(sidebar.selectionColor.alphaComponent <= 0.12)
    }

    @Test func anEntryWithNoPlaceIsDimmedAndGoesNowhere() throws {
        sidebar.setTheme(.paper)
        sidebar.show(entries, at: 0.1)
        var chosen: [String] = []
        sidebar.onChoose = { chosen.append($0.title) }
        sidebar.choose(row: 2)
        sidebar.choose(row: 3)
        #expect(chosen == ["Chapter 3"])
        let lost = try #require(sidebar.titleColor(row: 2)?.alphaComponent)
        let ahead = try #require(sidebar.titleColor(row: 3)?.alphaComponent)
        #expect(lost < ahead)
    }

    private func sameHue(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}
