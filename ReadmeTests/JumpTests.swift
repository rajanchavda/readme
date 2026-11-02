import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// The calls whose replies carry a location.
enum OvertakenCall: CaseIterable, Sendable {
    case settle, go, applyStyles
}

/// The images a curl or crossfade started with.
private struct Started {
    var front: CGImage?
    var back: CGImage?
    var beneathLeft: CGImage?
    var beneathRight: CGImage?
}

/// Moves nobody asked the coordinator or the cache for, such as a link in the book. The book is on
/// screen, as in the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct JumpTests {
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

    // MARK: The curl after a jump

    @Test func aLinkInTheBookIsFollowedByTheCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer()
        try await clickLink(to: "ch20.xhtml")
        #expect(view.currentLocation?.chapterTitle == "Chapter 20")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.forward, .backward])
    }

    @Test func aLinkWithinTheChapterIsFollowedByTheCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.1)
        try await clickLink(to: "ch5.xhtml#part-two")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.backward, .forward])
    }

    @Test func aJumpByFractionIsFollowedByTheCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer()
        _ = try #require(await view.go(toFraction: 0.7))
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.forward, .backward])
    }

    @Test func aJumpByCFIIsFollowedByTheCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer()
        let far = try await locationAfter(30)
        _ = try #require(await view.go(toCFI: far.cfi))
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.backward, .forward])
    }

    @Test func aSwipeAfterAJumpIsFollowedByTheCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer()
        try await clickLink(to: "ch20.xhtml")
        await cache.neighboursReady()
        let before = try await snapshot()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        let started = try await waitForCurl()
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        try expect(started, matches: .forward, from: before, to: try await snapshot())
    }

    // MARK: Pressing before the images are ready

    @Test func aPressStraightAfterALinkNeverCurlsFromTheOldPlace() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3)
        let old = try oldImages()
        try await clickLink(to: "ch20.xhtml")
        try await expectNoOldImages(old, whenTurning: .forward, with: turns)
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.forward])
    }

    @Test func aPressStraightAfterGoingToAFractionNeverCurlsFromTheOldPlace() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.5)
        let old = try oldImages()
        _ = try #require(await view.go(toFraction: 0.2))
        try await expectNoOldImages(old, whenTurning: .backward, with: turns)
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook(turns, [.backward])
    }

    @Test func aSwipeStraightAfterAJumpNeverCurlsFromTheOldPlace() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3)
        let old = try oldImages()
        try await clickLink(to: "ch20.xhtml")
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        // Whenever it starts, the curl must be from the new place.
        let started = try await waitForCurl()
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        expect(started, isNotFrom: old, going: .forward)
    }

    @Test func aCrossfadeStraightAfterAJumpNeverStartsFromTheOldPlace() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3, reduceMotion: true)
        let old = try oldImages()
        _ = try #require(await view.go(toFraction: 0.7))
        try await expectNoOldImages(old, whenTurning: .forward, with: turns)
    }

    // MARK: A jump while a page is on screen

    @Test func aJumpUnderAHeldPageLetsItGo() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer()
        turns.follow(.start(.forward))
        turns.follow(.move(250))
        #expect(curl.isShowing)
        let there = try #require(await view.go(toFraction: 0.7))
        try await waitWhile { curl.isShowing }
        #expect(!curl.isShowing)
        // The rest of the gesture belongs to a page that's gone.
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi == there.cfi)
        await cache.neighboursReady()
        try await expectCurrentSlotMatchesTheBook()
        try await expectCurlsMatchTheBook(turns, [.forward])
    }

    @Test func aLinkDuringACurlEndsItWithTheRightImages() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer(returningStart: true)
        let turns = coordinator()
        turns.turn(.forward)
        #expect(curl.isPlaying)
        // foliate ignores links until a turn has finished, which is well before the curl has.
        try await waitWhile { view.currentLocation?.cfi == start.cfi }
        try await Task.sleep(for: .milliseconds(160))
        try #require(curl.isPlaying)
        try await clickLink(to: "ch20.xhtml")
        try await waitWhile { curl.isShowing }
        #expect(!curl.isShowing)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.chapterTitle == "Chapter 20")
        await cache.neighboursReady()
        try await expectCurrentSlotMatchesTheBook()
        try await expectCurlsMatchTheBook(turns, [.forward, .backward])
    }

    // MARK: What isn't a jump

    /// bridge.js doesn't report the same place twice, so the report is sent straight from the page,
    /// as a repeat from anywhere would reach Swift. It's sent under a held page, which a jump would
    /// end, so it shows the report isn't taken for one.
    @Test func theSamePlaceReportedAgainChangesNothing() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3)
        let slots: [SpreadSlot] = [.current, .next, .previous, .afterNext, .beforePrevious]
        let before = slots.map { cache.image(for: $0) }
        turns.follow(.start(.forward))
        turns.follow(.move(250))
        try #require(curl.isShowing)
        var heard = 0
        view.onRelocate = { _ in heard += 1 }
        _ = try await view.call(
            """
            webkit.messageHandlers.readme.postMessage(
                JSON.stringify({ type: 'relocate', location: readmeBridge.location() }))
            """,
            as: Bool.self)
        try await waitWhile { heard == 0 }
        #expect(heard == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(curl.isShowing, "The held page was let go")
        await cache.neighboursReady()
        for (slot, image) in zip(slots, before) {
            #expect(cache.image(for: slot) === image, "\(slot) was rendered again")
        }
        turns.follow(.abandon)
        try await waitUntilDone(turns)
    }

    /// The turn's own settle can find the book a little further on, as when it paginates around
    /// content that came in late. That's still the turn's doing, so its curl plays out.
    @Test func aMoveReportedByATurnsSettleDoesNotCutItsCurl() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3)
        // Only the turn's settle calls this, and it moves the page as the bridge would report drift.
        _ = try await view.call(
            """
            const settled = readmeBridge.settled
            readmeBridge.settled = async () => {
                readmeBridge.settled = settled
                await document.querySelector('foliate-view').next()
                return settled()
            }
            """,
            as: Bool.self)
        turns.turn(.forward)
        let began = ContinuousClock.now
        #expect(curl.isPlaying)
        try await waitWhile { curl.isPlaying }
        let played = began.duration(to: .now)
        #expect(played >= .milliseconds(450), "The curl was cut off after \(played)")
        try await waitUntilDone(turns)
        await cache.neighboursReady()
        try await expectCurrentSlotMatchesTheBook()
        try await expectCurlsMatchTheBook(turns, [.forward, .backward])
    }

    // MARK: A relocation overtaking a reply

    /// A link's relocation can be handled before the continuation of a reply that left the page
    /// before it, and the reply's older location mustn't replace it.
    @Test(arguments: OvertakenCall.allCases)
    func aRelocationOvertakingAReplyIsKept(_ overtaken: OvertakenCall) async throws {
        defer { window.orderOut(nil) }
        _ = try await openWithFullBuffer(at: 0.3)
        view.replyArrived = { [self] in
            view.replyArrived = nil
            try? await clickLink(to: "ch20.xhtml")
        }
        switch overtaken {
        case .settle: await view.settle()
        case .go: _ = await view.go(toFraction: 0.35)
        case .applyStyles: await view.applyStyles(css: view.css, columns: view.columns)
        }
        #expect(view.currentLocation?.chapterTitle == "Chapter 20")
        let shown = try await view.call("return readmeBridge.location()", as: ReaderLocation.self)
        #expect(view.currentLocation?.cfi == shown?.cfi)
    }

    /// The same, overtaking the settle at the end of a turn, which is what labels a snapshot.
    @Test func aLinkOvertakingATurnsSettleLeavesTheRightImages() async throws {
        defer { window.orderOut(nil) }
        let turns = try await openWithFullBuffer(at: 0.3)
        var replies = 0
        view.replyArrived = { [self] in
            replies += 1
            // The first is the turn's move, the second its settle.
            guard replies == 2 else { return }
            view.replyArrived = nil
            try? await clickLink(to: "ch20.xhtml")
        }
        turns.turn(.forward)
        try await waitUntilDone(turns)
        #expect(replies == 2)
        await cache.neighboursReady()
        #expect(view.currentLocation?.chapterTitle == "Chapter 20")
        try await expectCurrentSlotMatchesTheBook()
        try await expectCurlsMatchTheBook(turns, [.forward, .backward])
    }

    @Test func theWindowStillHearsEveryMove() async throws {
        defer { window.orderOut(nil) }
        var heard: [String] = []
        view.onRelocate = { heard.append($0.cfi) }
        let turns = try await openWithFullBuffer()
        try await clickLink(to: "ch20.xhtml")
        let linked = try #require(view.currentLocation)
        let jumped = try #require(await view.go(toFraction: 0.5))
        await cache.neighboursReady()
        turns.turn(.forward)
        try await waitUntilDone(turns)
        let turned = try #require(view.currentLocation)
        #expect(heard.suffix(3) == [linked.cfi, jumped.cfi, turned.cfi])
    }

    // MARK: Helpers

    private func coordinator(reduceMotion: Bool = false) -> TurnCoordinator {
        TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { reduceMotion })
    }

    private func openWithFullBuffer(at fraction: Double? = nil, reduceMotion: Bool = false) async throws -> TurnCoordinator {
        _ = try await openWithFullBuffer(at: fraction, returningStart: true)
        return coordinator(reduceMotion: reduceMotion)
    }

    private func openWithFullBuffer(at fraction: Double? = nil, returningStart: Bool) async throws -> ReaderLocation {
        window.orderFrontRegardless()
        var location = try await view.open(fixture("long.epub"), at: nil)
        if let fraction { location = try #require(await view.go(toFraction: fraction)) }
        await cache.refresh(around: location)
        await cache.neighboursReady()
        return location
    }

    private let clickScript = """
        const doc = readmeBridge.currentDocument()
        const link = doc.createElement('a')
        link.setAttribute('href', href)
        link.style.display = 'none'
        doc.body.append(link)
        link.click()
        link.remove()
        """

    /// Clicks a link in the page, through foliate's own handling, as a reader's click would go, and
    /// returns once the book has said where it went.
    private func clickLink(to href: String) async throws {
        let before = view.currentLocation?.cfi
        _ = try await view.call(clickScript, arguments: ["href": href], as: Bool.self)
        try await waitWhile { view.currentLocation?.cfi == before }
        try #require(view.currentLocation?.cfi != before, "The link went nowhere")
    }

    private func waitWhile(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitUntilDone(_ turns: TurnCoordinator) async throws {
        try await waitWhile { turns.isTurning }
    }

    private func started() -> Started? {
        if curl.isCrossfading {
            return Started(beneathLeft: curl.beneathLayers.left?.contents as! CGImage?)
        }
        guard let faces = curl.stripFaces.first else { return nil }
        return Started(
            front: (faces.front.contents as! CGImage), back: (faces.back.contents as! CGImage),
            beneathLeft: curl.beneathLayers.left?.contents as! CGImage?,
            beneathRight: curl.beneathLayers.right?.contents as! CGImage?)
    }

    private func waitForCurl() async throws -> Started {
        try await waitWhile { started() == nil }
        return try #require(started(), "No curl started")
    }

    /// Turns, watching for the curl until the turn's done. Nil if the page changed without one.
    private func turnWatching(_ turns: TurnCoordinator, _ direction: TurnDirection) async throws -> Started? {
        turns.turn(direction)
        var seen = started()
        while turns.isTurning {
            if seen == nil { seen = started() }
            try await Task.sleep(for: .milliseconds(1))
        }
        return seen
    }

    /// Each turn must curl, from the spread on screen to the one it lands on.
    private func expectCurlsMatchTheBook(
        _ turns: TurnCoordinator, _ directions: [TurnDirection],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for direction in directions {
            let before = try await snapshot()
            let seen = try await turnWatching(turns, direction)
            let after = try await snapshot()
            let started = try #require(seen, "The \(direction) turn didn't curl", sourceLocation: sourceLocation)
            try expect(started, matches: direction, from: before, to: after, sourceLocation: sourceLocation)
            await cache.neighboursReady()
        }
    }

    private func expect(
        _ started: Started, matches direction: TurnDirection, from before: CGImage, to after: CGImage,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let expected = try #require(TurnImages(direction, current: before, target: after), sourceLocation: sourceLocation)
        let pairs: [(String, CGImage?, CGImage)] = [
            ("front", started.front, expected.front), ("back", started.back, expected.back),
            ("beneath left", started.beneathLeft, expected.beneathLeft),
            ("beneath right", started.beneathRight, expected.beneathRight),
        ]
        for (name, image, wanted) in pairs {
            let image = try #require(image, "No \(name) image", sourceLocation: sourceLocation)
            let difference = ImageDiff.fractionDifferent(image, wanted)
            #expect(
                difference < SpreadCacheTests.landingTolerance,
                "The \(direction) curl's \(name) differs from the book by \(difference)", sourceLocation: sourceLocation)
        }
    }

    private struct OldImages {
        let current: CGImage
        let next: CGImage
        let previous: CGImage
    }

    private func oldImages() throws -> OldImages {
        OldImages(
            current: try #require(cache.image(for: .current)), next: try #require(cache.image(for: .next)),
            previous: try #require(cache.image(for: .previous)))
    }

    /// Presses at once, while the cache is still rendering the new place, and checks any curl or
    /// crossfade that starts.
    private func expectNoOldImages(
        _ old: OldImages, whenTurning direction: TurnDirection, with turns: TurnCoordinator,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let before = try #require(view.currentLocation?.cfi)
        let seen = try await turnWatching(turns, direction)
        #expect(view.currentLocation?.cfi != before, "The press didn't turn the page", sourceLocation: sourceLocation)
        guard let seen else { return }
        expect(seen, isNotFrom: old, going: direction, sourceLocation: sourceLocation)
    }

    private func expect(
        _ started: Started, isNotFrom old: OldImages, going direction: TurnDirection,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let oldTarget = direction == .forward ? old.next : old.previous
        var candidates: [(String, CGImage?, CGImage?)] = []
        if curl.isCrossfading || started.front == nil {
            candidates.append(("crossfade target", started.beneathLeft, oldTarget))
        } else if let oldPieces = TurnImages(direction, current: old.current, target: oldTarget) {
            candidates += [
                ("front", started.front, oldPieces.front), ("back", started.back, oldPieces.back),
                ("beneath left", started.beneathLeft, oldPieces.beneathLeft),
                ("beneath right", started.beneathRight, oldPieces.beneathRight),
            ]
        }
        for case let (name, image?, stale?) in candidates {
            let difference = ImageDiff.fractionDifferent(image, stale)
            #expect(difference > 0.01, "The curl's \(name) is the old place's", sourceLocation: sourceLocation)
        }
    }

    private func expectCurrentSlotMatchesTheBook(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let current = try #require(cache.image(for: .current), sourceLocation: sourceLocation)
        let difference = ImageDiff.fractionDifferent(current, try await snapshot())
        #expect(difference < SpreadCacheTests.landingTolerance, "current differs by \(difference)", sourceLocation: sourceLocation)
    }

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
