import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The book is on screen, as in the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct RapidTurnTests {
    let window: NSWindow
    let view: BookWebView
    let cache: SpreadCache
    let curl: CurlView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: frame)
        view = BookWebView(frame: frame)
        curl = CurlView(frame: frame)
        content.addSubview(view)
        content.addSubview(curl)
        window.contentView = content
        cache = SpreadCache(visible: view)
    }

    /// Thirty presses at key-repeat speed, far faster than the curl: every one has to count, and the
    /// images have to end up belonging to wherever the book did.
    @Test func heldKeyLandsCorrectly() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(30)

        window.orderFrontRegardless()
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        await cache.neighboursReady()

        let turns = TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { false })
        for _ in 0..<30 {
            turns.turn(.forward)
            try await Task.sleep(for: .milliseconds(50))
        }
        while turns.isTurning { try await Task.sleep(for: .milliseconds(10)) }
        await cache.neighboursReady()

        #expect(view.currentLocation?.cfi == expected.cfi)
        let current = try #require(cache.image(for: .current))
        let shown = try await snapshot()
        #expect(ImageDiff.fractionDifferent(current, shown) < SpreadCacheTests.landingTolerance)
    }

    /// A held key's repeats, at macOS's fastest and default rates. Pages stop when it's let go, so
    /// repeats that arrive while a move is landing are dropped rather than kept for later.
    @Test(arguments: [30, 90]) func heldKeyStopsOnRelease(repeatEvery interval: Int) async throws {
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        await cache.neighboursReady()
        let turns = TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { false })

        var seen = start.cfi
        var lastMove = ContinuousClock.now
        var moves = 0
        let watch = {
            guard let here = view.currentLocation?.cfi, here != seen else { return }
            seen = here
            lastMove = .now
            moves += 1
        }
        turns.turn(.forward)
        let pressed = ContinuousClock.now
        var nextRepeat = pressed + .milliseconds(interval)
        while nextRepeat < pressed + .seconds(3) {
            while ContinuousClock.now < nextRepeat {
                watch()
                try await Task.sleep(for: .milliseconds(1))
            }
            turns.turn(.forward, isRepeat: true)
            nextRepeat += .milliseconds(interval)
        }
        let released = ContinuousClock.now
        while turns.isTurning || ContinuousClock.now < released + .seconds(1) {
            watch()
            try await Task.sleep(for: .milliseconds(1))
        }

        #expect(moves > 5)
        let runOn = lastMove - released
        #expect(runOn < .milliseconds(200), "The page kept turning for \(runOn) after the key was let go")
        let shown = try await view.call("return readmeBridge.location()", as: ReaderLocation.self)
        #expect(view.currentLocation?.cfi == shown?.cfi)
        await cache.neighboursReady()
        let current = try #require(cache.image(for: .current))
        #expect(ImageDiff.fractionDifferent(current, try await snapshot()) < SpreadCacheTests.landingTolerance)

        turns.turn(.forward)
        #expect(curl.isPlaying, "A press after the key was let go didn't curl")
        while turns.isTurning { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Where `count` forward turns should end up, found by walking in a second view.
    private func locationAfter(_ count: Int) async throws -> ReaderLocation {
        let otherWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let walker = BookWebView(frame: view.frame)
        otherWindow.contentView = walker
        var location = try await walker.open(fixture("long.epub"), at: nil)
        for _ in 0..<count { location = try #require(await walker.next()) }
        return location
    }

    private func snapshot() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            view.webView.takeSnapshot(with: nil) { image, error in
                if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: error ?? BookWebViewError.timedOut)
                }
            }
        }
    }
}
