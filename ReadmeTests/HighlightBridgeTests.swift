import AppKit
import Foundation
import Testing
import WebKit
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Drives the real page: selects words in the book's own document and sees what the app hears.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct HighlightBridgeTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    private static let doc = "document.querySelector('foliate-view').renderer.getContents()[0].doc"

    /// Selects the first twenty characters of the first real text and lets go of the mouse.
    private func selectFirstWords() async throws {
        _ = try await view.call("""
            const doc = \(Self.doc)
            const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
            let node = walker.nextNode()
            while (node && node.textContent.trim().length < 30) node = walker.nextNode()
            const range = doc.createRange()
            range.setStart(node, 0)
            range.setEnd(node, 20)
            const selection = doc.defaultView.getSelection()
            selection.removeAllRanges()
            selection.addRange(range)
            doc.dispatchEvent(new Event('pointerup'))
            return true
            """, as: Bool.self)
    }

    private func marks() async throws -> Int {
        try await view.call(
            "return \(Self.doc.replacingOccurrences(of: ".doc", with: ".overlayer.element")).querySelectorAll('g').length",
            as: Int.self) ?? -1
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func selectingWordsReportsThem() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        var heard: BookWebView.SelectionInfo?
        view.onSelection = { heard = $0 ?? heard }
        try await selectFirstWords()
        await waitFor { heard != nil }
        let info = try #require(heard)
        #expect(info.cfi.contains(","))
        #expect(!info.text.isEmpty)
        #expect(info.rect.width > 0)
        #expect((0...1).contains(info.fraction))
    }

    @Test func collapsedSelectionIsReportedAsNone() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        try await selectFirstWords()
        var events: [Bool] = []
        view.onSelection = { events.append($0 != nil) }
        await view.clearSelection()
        await waitFor { events.contains(false) }
        #expect(events.contains(false))
    }

    @Test func addedHighlightIsDrawnAndRemovable() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        var heard: BookWebView.SelectionInfo?
        view.onSelection = { heard = $0 ?? heard }
        try await selectFirstWords()
        await waitFor { heard != nil }
        let cfi = try #require(heard).cfi
        #expect(try await marks() == 0)
        await view.addHighlight(cfi)
        #expect(try await marks() == 1)
        await view.removeHighlight(cfi)
        #expect(try await marks() == 0)
    }

    @Test func highlightsGivenBeforeOpenAreDrawnOnOpen() async throws {
        let url = try fixture("long.epub")
        _ = try await view.open(url, at: nil)
        var heard: BookWebView.SelectionInfo?
        view.onSelection = { heard = $0 ?? heard }
        try await selectFirstWords()
        await waitFor { heard != nil }
        let cfi = try #require(heard).cfi

        let other = BookWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let second = NSWindow(contentRect: other.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        second.contentView = other
        await other.setHighlights([cfi], color: "#f2c744")
        _ = try await other.open(url, at: nil)
        await other.settle()
        let drawn = try await other.call(
            "return document.querySelector('foliate-view').renderer.getContents()[0].overlayer.element.querySelectorAll('g').length",
            as: Int.self)
        #expect(drawn == 1)
    }

    @Test func clickingAHighlightIsReported() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        var heard: BookWebView.SelectionInfo?
        view.onSelection = { heard = $0 ?? heard }
        try await selectFirstWords()
        await waitFor { heard != nil }
        let info = try #require(heard)
        await view.addHighlight(info.cfi)
        var clicked: String?
        view.onHighlightClicked = { cfi, _ in clicked = cfi }
        _ = try await view.call("""
            const doc = \(Self.doc)
            const p = doc.querySelector('p').getBoundingClientRect()
            doc.dispatchEvent(new MouseEvent('click', { clientX: p.left + 2, clientY: p.top + 2, bubbles: true }))
            return true
            """, as: Bool.self)
        await waitFor { clicked != nil }
        #expect(clicked == info.cfi)
    }
}
