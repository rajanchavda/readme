import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The page says whether the spread on show holds the reading marker.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct MarkerBridgeTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    private func css(fontSize: Double) -> String {
        var settings = ReaderSettings()
        settings.fontSize = fontSize
        return ReadingCSS.css(settings, theme: .paper, fullscreen: false)
    }

    @Test func markedSpreadIsMarkedAndOthersAreNot() async throws {
        await view.applyStyles(css: css(fontSize: 18), columns: 2)
        _ = try await view.open(fixture("long.epub"), at: nil)
        // Away from the start, so there's a spread before it.
        _ = await view.go(toFraction: 0.3)
        #expect(view.currentLocation?.isMarked == false)

        let place = try #require(await view.place())
        let stored = try #require(await view.setMarker(place))
        #expect(!stored.contains(","))
        #expect(view.currentLocation?.isMarked == true)

        let next = try #require(await view.next())
        #expect(!next.isMarked)
        let back = try #require(await view.previous())
        #expect(back.isMarked)

        // A bigger font lays the book out again, and the spread the reader's on still holds it.
        await view.applyStyles(css: css(fontSize: 26), columns: 2)
        await view.settle()
        #expect(view.currentLocation?.isMarked == true)

        _ = await view.setMarker(nil)
        #expect(view.currentLocation?.isMarked == false)
    }

    @Test func markerGivenBeforeOpenIsKnownOnOpen() async throws {
        let url = try fixture("long.epub")
        _ = try await view.open(url, at: nil)
        _ = await view.go(toFraction: 0.5)
        let place = try #require(await view.place())

        let other = BookWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let second = NSWindow(contentRect: other.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        second.contentView = other
        _ = await other.setMarker(place)
        let atStart = try await other.open(url, at: nil)
        #expect(!atStart.isMarked)
        let there = try #require(await other.go(toCFI: place))
        #expect(there.isMarked)
    }
}
