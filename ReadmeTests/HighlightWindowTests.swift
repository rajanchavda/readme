import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The sidebar's rows: reading order is the store's, and a row is chosen or removed by its highlight.
@MainActor
@Suite struct HighlightsSidebarTests {
    @Test func choosingAndRemovingARowHandsOverItsHighlight() {
        let sidebar = HighlightsSidebar(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
        let one = Highlight(cfi: "epubcfi(/6/2!/4,/1:0,/1:4)", text: "one", fraction: 0.1)
        let two = Highlight(cfi: "epubcfi(/6/4!/4,/1:0,/1:4)", text: "two", fraction: 0.2)
        sidebar.show([one, two])
        var chosen: Highlight?
        var removed: Highlight?
        sidebar.onChoose = { chosen = $0 }
        sidebar.onRemove = { removed = $0 }
        sidebar.choose(row: 1)
        sidebar.remove(row: 0)
        #expect(chosen == two)
        #expect(removed == one)
        sidebar.choose(row: 5)
        #expect(chosen == two)
    }
}

/// Selecting words in the window, highlighting them, and finding them again.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct HighlightWindowTests {
    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func highlightingASelectionKeepsItAndListsIt() async throws {
        let saved = ReaderSettings.store.data(forKey: ReaderSettings.key)
        defer { ReaderSettings.store.set(saved, forKey: ReaderSettings.key) }
        let folder = try positionsFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        let reader = ReaderWindowController(
            positions: PositionStore(directory: folder.appendingPathComponent("Positions")), library: library)
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        await reader.settled()
        let book = try #require(reader.book)

        _ = try await book.call("""
            const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc
            const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
            let node = walker.nextNode()
            while (node && node.textContent.trim().length < 30) node = walker.nextNode()
            const range = doc.createRange(); range.setStart(node, 0); range.setEnd(node, 20)
            const selection = doc.getSelection(); selection.removeAllRanges(); selection.addRange(range)
            doc.dispatchEvent(new Event('pointerup'))
            return true
            """, as: Bool.self)
        await waitFor { reader.highlightBarMode != nil }
        #expect(reader.highlightBarMode == .add)

        reader.pressHighlightBar()
        await waitFor { reader.highlightBarMode == nil && !book.highlightCFIs.isEmpty }
        #expect(reader.highlightBarMode == nil)
        #expect(book.highlightCFIs.count == 1)

        reader.perform(.toggleHighlights)
        await waitFor { reader.isShowingHighlights }
        #expect(reader.isShowingHighlights)
        #expect(reader.highlightsShown.count == 1)
        #expect(reader.highlightsShown.first?.text == "sail turned that men")

        // Opening the contents puts the highlights away.
        reader.perform(.toggleTOC)
        await reader.settled()
        #expect(!reader.isShowingHighlights)
    }
}
