import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The dim number in the corner of each spread: the page the spread starts on.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct PageNumberTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    private func css(fontSize: Double, theme: Theme = .paper) -> String {
        var settings = ReaderSettings()
        settings.fontSize = fontSize
        return ReadingCSS.css(settings, theme: theme, fullscreen: false)
    }

    private func open(theme: Theme = .paper) async throws -> ReaderLocation {
        await view.applyStyles(css: css(fontSize: 18, theme: theme), columns: 2)
        return try await view.open(fixture("long.epub"), at: nil)
    }

    @Test func pageNumberIsTheSpreadsStartPage() async throws {
        let first = try await open()
        #expect(await view.pageLabel()?.text == String(first.page))
        let landed = try #require(await view.go(toPage: 40))
        #expect(await view.pageLabel()?.text == String(landed.page))
        let next = try #require(await view.next())
        #expect(await view.pageLabel()?.text == String(next.page))
    }

    @Test func pageNumberSurvivesARestyle() async throws {
        _ = try await open()
        _ = await view.go(toPage: 40)
        await view.applyStyles(css: css(fontSize: 26), columns: 1)
        await view.settle()
        let here = try #require(view.currentLocation)
        #expect(await view.pageLabel()?.text == String(here.page))
    }

    @Test func pageNumberTakesThePageInk() async throws {
        _ = try await open(theme: .night)
        await view.settle()
        let label = try #require(await view.pageLabel())
        let ink = try #require(try await view.call(
            "const d = readmeBridge.currentDocument(); return d.defaultView.getComputedStyle(d.body).color",
            as: String.self))
        #expect(label.color == ink)
        #expect(label.color != "rgb(0, 0, 0)")
    }
}
