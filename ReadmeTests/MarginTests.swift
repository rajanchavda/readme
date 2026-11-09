import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

private func scratchDefaults() -> UserDefaults {
    let name = "MarginTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// The text columns on screen, in the page's points from its left edge, and the page's size.
private struct Shown: Decodable {
    var width: Double
    var height: Double
    var columns: [[Double]]
}

/// The columns the body is laid out in that are on the visible spread, placed in the page.
private let columnsJS = """
const view = document.querySelector('foliate-view')
const doc = view.renderer.getContents()[0].doc
const frame = doc.defaultView.frameElement.getBoundingClientRect()
const width = window.innerWidth, height = window.innerHeight
const columns = [...doc.body.getClientRects()]
    .map(r => [frame.left + r.left, frame.left + r.right, frame.top + r.top, frame.top + r.bottom])
    .filter(([left, right]) => left >= -1 && right <= width + 1)
return { width, height, columns }
"""

/// A book's margins: the text stands as far from the spine as from the page's outer edge, the same
/// on both pages, and on a single page the same on both sides.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10))) struct MarginTests {
    @Test func theInnerMarginsMatchTheOuterOnes() async throws {
        let defaults = scratchDefaults()
        let reader = ReaderWindowController(defaults: defaults)
        defer { reader.window?.close() }
        reader.window?.setFrameAutosaveName("")
        reader.window?.setContentSize(NSSize(width: 1048, height: 620))
        reader.window?.orderFrontRegardless()
        await reader.open(try fixture("long.epub"))
        await reader.settled()
        reader.goToPage(typed: "30")
        await reader.settled()

        var spreads = 0, singles = 0
        for window in [NSSize(width: 1048, height: 620), NSSize(width: 1500, height: 900), NSSize(width: 700, height: 620)] {
            reader.window?.setContentSize(window)
            for lineWidth in LineWidth.allCases {
                for size in [14.0, 18, 24] {
                    var settings = ReaderSettings.load(defaults)
                    settings.lineWidth = lineWidth
                    settings.fontSize = size
                    reader.change(settings)
                    await reader.settled()
                    await reader.book?.settle()
                    let book = try #require(reader.book)
                    let shown = try #require(try await book.call(columnsJS, as: Shown.self))
                    let label = "\(size)px \(lineWidth), \(Int(window.width)) wide"
                    try #require(shown.columns.count == reader.layoutColumns, "\(label): \(shown.columns)")
                    let left = shown.columns[0]
                    if reader.layoutColumns == 2 {
                        spreads += 1
                        let right = shown.columns[1]
                        let spine = shown.width / 2
                        let margins = (
                            leftOuter: left[0], leftInner: spine - left[1],
                            rightInner: right[0] - spine, rightOuter: shown.width - right[1])
                        #expect(abs(margins.leftInner - margins.leftOuter) <= 2, "\(label): \(margins)")
                        #expect(abs(margins.rightInner - margins.rightOuter) <= 2, "\(label): \(margins)")
                        #expect(abs(margins.leftOuter - margins.rightOuter) <= 2, "\(label): \(margins)")
                        // The text stays clear of the spine's shadow.
                        #expect(margins.leftInner > SpineShadow.reach && margins.rightInner > SpineShadow.reach,
                                "\(label): \(margins)")
                    } else {
                        singles += 1
                        let margins = (left: left[0], right: shown.width - left[1])
                        #expect(abs(margins.left - margins.right) <= 2, "\(label): \(margins)")
                    }
                }
            }
        }
        #expect(spreads >= 6 && singles >= 3, "\(spreads) spreads, \(singles) single pages")
    }
}
