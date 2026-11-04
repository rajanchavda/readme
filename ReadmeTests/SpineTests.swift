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
    let name = "SpineTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Something laid out outside every column, which shows in the gap between the pages, under the
/// spine, or on the facing page.
private struct Overrun: Decodable, CustomStringConvertible {
    var section: Int
    var tag: String
    var text: String
    var left: Double
    var right: Double
    var columns: String

    var description: String { "section \(section) <\(tag)> \(left)...\(right) outside \(columns): \(text)" }
}

/// Goes through every section of the open book and returns each text line, and each box of an
/// element, that isn't inside one of the columns the body is laid out in.
private let overrunsJS = """
const view = document.querySelector('foliate-view')
const found = []
const sections = view.book.sections
for (let index = 0; index < sections.length; index++) {
    if (sections[index].linear === 'no') continue
    await view.goTo(index)
    await new Promise(resolve => setTimeout(resolve, 50))
    const doc = view.renderer.getContents()[0]?.doc
    if (!doc?.body) continue
    const columns = [...doc.body.getClientRects()].map(r => [r.left, r.right])
    const inside = r => columns.some(([left, right]) => r.left >= left - 1 && r.right <= right + 1)
    const describe = (tag, text, r) => found.push({
        section: index, tag, text: text.trim().slice(0, 50), left: Math.round(r.left), right: Math.round(r.right),
        columns: columns.slice(0, 2).map(c => c.map(Math.round).join('-')).join(', '),
    })
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
    for (let node; (node = walker.nextNode());) {
        if (!node.textContent.trim()) continue
        const range = doc.createRange()
        range.selectNodeContents(node)
        const outside = [...range.getClientRects()].find(r => r.width >= 0.5 && !inside(r))
        if (outside) describe(node.parentElement.tagName.toLowerCase(), node.textContent, outside)
    }
    for (const element of doc.body.querySelectorAll('*')) {
        const outside = [...element.getClientRects()].find(r => r.width >= 0.5 && !inside(r))
        if (outside) describe(element.tagName.toLowerCase(), element.textContent ?? '', outside)
    }
}
return found
"""

/// Text is set in its own column: nothing runs into the gap between the pages, under the spine, or
/// onto the facing page, whatever the book asks for, in any font, size or line width.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10))) struct SpineTests {
    @Test func nothingRunsOutOfItsColumn() async throws {
        let defaults = scratchDefaults()
        let reader = ReaderWindowController(defaults: defaults)
        defer { reader.window?.close() }
        reader.window?.setFrameAutosaveName("")
        reader.window?.setContentSize(NSSize(width: 1048, height: 620))
        reader.window?.orderFrontRegardless()
        await reader.open(try fixture("wide-content.epub"))
        await reader.settled()

        var twoPageSettings = 0
        for window in [NSSize(width: 1048, height: 620), NSSize(width: 1700, height: 900)] {
            reader.window?.setContentSize(window)
            for font in BookFont.allCases {
                for lineWidth in LineWidth.allCases {
                    for size in [14.0, 18, 28] {
                        var settings = ReaderSettings.load(defaults)
                        settings.font = font
                        settings.lineWidth = lineWidth
                        settings.fontSize = size
                        reader.change(settings)
                        await reader.settled()
                        await reader.book?.settle()
                        if reader.layoutColumns == 2 { twoPageSettings += 1 }
                        let book = try #require(reader.book)
                        let overruns = try #require(try await book.call(
                            overrunsJS, as: [Overrun].self, timeout: .seconds(60)))
                        #expect(
                            overruns.isEmpty,
                            "\(font) \(size)px \(lineWidth), \(Int(window.width)) wide, \(reader.layoutColumns) pages: \(overruns.prefix(4))")
                    }
                }
            }
        }
        // The spine is only there with two pages, so enough of these must be two.
        #expect(twoPageSettings >= 10, "Only \(twoPageSettings) settings showed two pages")
    }
}
