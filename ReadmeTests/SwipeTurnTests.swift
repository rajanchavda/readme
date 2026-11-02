import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Swipes driven through `TurnCoordinator.follow`, as `DeskView` drives them. The page is 500
/// points wide, so a move of 300 is progress 0.6.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct SwipeTurnTests {
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

    private func coordinator(reduceMotion: Bool = false) -> TurnCoordinator {
        TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { reduceMotion })
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

    private func openWithFullBuffer(at fraction: Double? = nil) async throws -> ReaderLocation {
        window.orderFrontRegardless()
        var location = try await view.open(fixture("long.epub"), at: nil)
        if let fraction { location = try #require(await view.go(toFraction: fraction)) }
        await cache.refresh(around: location)
        await cache.neighboursReady()
        return location
    }

    private func waitUntilDone(_ turns: TurnCoordinator) async throws {
        while turns.isTurning { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func waitForCurl() async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while curl.stripLayers.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
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

    // MARK: Following

    @Test func theCurlFollowsForwardFingersAndTheBookWaits() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        #expect(curl.direction == .forward)
        #expect(curl.progress == 0)
        #expect(curl.stripLayers.count == CurlPose.strips)
        #expect(!curl.isPlaying)
        turns.follow(.move(250))
        #expect(curl.progress == 0.5)
        turns.follow(.move(-100))
        #expect(curl.progress == 0.3)
        #expect(!curl.isPlaying)
        #expect(turns.isTurning)

        try await Task.sleep(for: .milliseconds(200))
        #expect(view.currentLocation?.cfi == start.cfi)
        #expect(curl.progress == 0.3)
        turns.follow(.abandon)
        try await waitUntilDone(turns)
    }

    /// Going back is the same curl run down from 1, so the page comes over the spine under the fingers.
    @Test func theCurlFollowsBackwardFingersDownFromTheEnd() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer(at: 0.5)
        let turns = coordinator()
        turns.follow(.start(.backward))
        #expect(curl.direction == .backward)
        #expect(curl.progress == 1)
        turns.follow(.move(100))
        #expect(curl.progress == 0.8)
        turns.follow(.move(1000))
        #expect(curl.progress == 0)
        turns.follow(.move(-250))
        #expect(curl.progress == 0.5)
        #expect(view.currentLocation?.cfi == start.cfi)
        turns.follow(.abandon)
        try await waitUntilDone(turns)
    }

    // MARK: Letting go

    @Test func aCommittedReleaseFinishesFromThereAndLands() async throws {
        defer { window.orderOut(nil) }
        _ = try await openWithFullBuffer()
        let promised = try #require(cache.image(for: .next))
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        #expect(curl.progress == 0.6)
        try await waitUntilDone(turns)

        #expect(!curl.isShowing)
        #expect(curl.progress > 0.6)
        let difference = try ImageDiff.fractionDifferent(await snapshot(), promised)
        #expect(difference < SpreadCacheTests.landingTolerance)
    }

    /// Only what's left of the 520 ms is played.
    @Test func aReleaseNearTheEndFinishesQuickly() async throws {
        defer { window.orderOut(nil) }
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(450))
        let released = ContinuousClock.now
        turns.follow(.release(velocity: 0))
        while curl.isPlaying { try await Task.sleep(for: .milliseconds(2)) }
        #expect(ContinuousClock.now - released < .milliseconds(250))
        try await waitUntilDone(turns)
    }

    @Test func aReleaseAtTheVeryEndStillLands() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(1000))
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    @Test func aReleaseBeforeHalfwayFallsBackAndNothingMoves() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let next = try #require(cache.image(for: .next))
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(150))
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        #expect(curl.progress == 0.3)
        // What it falls back to is the page it left.
        curl.snapToEnd()
        #expect(curl.stripLayers.isEmpty)
        #expect(curl.beneathLayers.right?.contents != nil)
        try await waitUntilDone(turns)

        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi == start.cfi)
        #expect(cache.image(for: .next) === next)
    }

    @Test func aFlickFromNearTheStartCommits() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(100))
        turns.follow(.release(velocity: 700))
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    @Test func aReverseFlickFromNearTheEndFallsBack() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(350))
        turns.follow(.release(velocity: -700))
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    @Test func aBackwardCommitLandsOnThePreviousSpread() async throws {
        defer { window.orderOut(nil) }
        _ = try await openWithFullBuffer(at: 0.5)
        let promised = try #require(cache.image(for: .previous))
        let turns = coordinator()
        turns.follow(.start(.backward))
        turns.follow(.move(300))
        #expect(abs(curl.progress - 0.4) < 1e-9)
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        try await waitUntilDone(turns)
        #expect(curl.progress < 0.4)
        let difference = try ImageDiff.fractionDifferent(await snapshot(), promised)
        #expect(difference < SpreadCacheTests.landingTolerance)
    }

    @Test func aBackwardFallBackStaysPut() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer(at: 0.5)
        let turns = coordinator()
        turns.follow(.start(.backward))
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        try await waitUntilDone(turns)
        #expect(curl.progress > 0.8)
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    @Test func anAbandonedSwipeFallsBackHoweverFarItWent() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(450))
        turns.follow(.abandon)
        #expect(curl.isPlaying)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    @Test func whatComesAfterTheReleaseChangesNothing() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(1)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        turns.follow(.abandon)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    // MARK: The ends of the book

    @Test func aSwipeOffEitherEndOfTheBookDoesNothing() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        #expect(start.isAtStart)
        let turns = coordinator()
        turns.follow(.start(.backward))
        turns.follow(.move(400))
        #expect(!turns.isTurning)
        #expect(!curl.isShowing)
        turns.follow(.release(velocity: 1000))
        #expect(!turns.isTurning)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.currentLocation?.cfi == start.cfi)

        let end = try #require(await view.go(toFraction: 1))
        #expect(end.isAtEnd)
        await cache.refresh(around: end)
        turns.follow(.start(.forward))
        turns.follow(.move(400))
        #expect(!turns.isTurning)
        #expect(!curl.isShowing)
        turns.follow(.release(velocity: 1000))
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.currentLocation?.cfi == end.cfi)
    }

    // MARK: Images that aren't ready

    @Test func aCurlPicksUpAtTheFingersWhenTheImagesArrive() async throws {
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(200))
        #expect(turns.isTurning)
        #expect(curl.stripLayers.isEmpty)
        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi == start.cfi)

        await cache.refresh(around: start)
        try await waitForCurl()
        #expect(curl.stripLayers.count == CurlPose.strips)
        #expect(curl.progress == 0.4)
        turns.follow(.move(100))
        #expect(curl.progress == 0.6)
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    @Test func aCommitWithoutImagesJustChangesThePage() async throws {
        defer { window.orderOut(nil) }
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))
        #expect(turns.isTurning)
        #expect(!curl.isShowing)
        while turns.isTurning {
            #expect(!curl.isShowing)
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    /// The images are right on hand by then, but the fingers have already gone: no curl plays.
    @Test func imagesArrivingOnlyAfterTheReleaseAreNotCurled() async throws {
        defer { window.orderOut(nil) }
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))
        await cache.refresh(around: start)
        #expect(curl.stripLayers.isEmpty)
        try await waitUntilDone(turns)
        #expect(curl.stripLayers.isEmpty)
    }

    @Test func aFallBackWithoutImagesDoesNothing() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        #expect(!turns.isTurning)
        #expect(!curl.isShowing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    // MARK: Keys during a swipe

    /// Fingers down, a press counts as the fingers letting go, standing still. Then it does what a
    /// press does during a finishing curl: snaps it and turns.
    @Test func aPressWithTheSwipePastHalfwayCommitsItThenTurns() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(2)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.turn(.forward)
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(!curl.isShowing)
    }

    @Test func aPressWithTheSwipeBeforeHalfwayFallsBackThenTurns() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(1)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(100))
        turns.turn(.forward)
        // Its curl is the press's own, timed from the start.
        #expect(curl.isPlaying)
        #expect(curl.progress == 0)
        turns.follow(.move(100))
        #expect(curl.progress == 0)
        turns.follow(.release(velocity: 2000))
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(!curl.isShowing)
    }

    @Test func aPressDuringASwipeWaitingForImagesFollowsTheSameRule() async throws {
        let expected = try await locationAfter(2)
        _ = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.turn(.forward)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    // MARK: During a finishing animation

    @Test func aPressDuringAFinishSnapsItAndTurnsOn() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(2)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        try await Task.sleep(for: .milliseconds(30))
        turns.turn(.forward)
        #expect(curl.progress == 0 || curl.stripLayers.isEmpty)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    @Test func aPressDuringAFallBackSnapsItAndTurns() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(1)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(200))
        turns.follow(.release(velocity: 0))
        #expect(curl.isPlaying)
        turns.turn(.forward)
        #expect(curl.isPlaying)
        #expect(curl.progress == 0)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(!curl.isShowing)
    }

    /// The move before it hasn't landed, so its images can't be trusted until it has.
    @Test func aSecondSwipeDuringAFinishSnapsItAndPicksUpAfterTheLanding() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(2)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        turns.follow(.release(velocity: 0))

        turns.follow(.start(.forward))
        #expect(!curl.isPlaying)
        turns.follow(.move(300))
        try await waitForCurl()
        #expect(curl.progress == 0.6)
        #expect(!curl.isPlaying)
        turns.follow(.release(velocity: 0))
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(!curl.isShowing)
    }

    /// The press's curl has a pending uncovering that mustn't take the swipe's curl away with it.
    @Test func aCurlBeforeTheSwipeCannotLiftTheSwipesCurl() async throws {
        defer { window.orderOut(nil) }
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.turn(.forward)
        try await Task.sleep(for: .milliseconds(200))
        turns.follow(.start(.forward))
        turns.follow(.move(100))
        // At once if the move has landed, and otherwise when it does, which a busy machine can delay.
        try await waitForCurl()
        #expect(curl.stripLayers.count == CurlPose.strips)
        // Long past the earlier landing's settling, painting and timeout.
        try await Task.sleep(for: .seconds(1))
        #expect(curl.isShowing)
        #expect(curl.stripLayers.count == CurlPose.strips)
        #expect(curl.progress == 0.2)
        turns.follow(.abandon)
        try await waitUntilDone(turns)
    }

    // MARK: Less motion

    @Test func withLessMotionNothingFollowsAndACommitCrossfades() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator(reduceMotion: true)
        turns.follow(.start(.forward))
        turns.follow(.move(300))
        #expect(curl.stripLayers.isEmpty)
        #expect(!curl.isShowing)
        turns.follow(.release(velocity: 0))
        #expect(curl.isCrossfading)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
        #expect(!curl.isShowing)
    }

    @Test func withLessMotionAFallBackDoesNothing() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer()
        let turns = coordinator(reduceMotion: true)
        turns.follow(.start(.forward))
        turns.follow(.move(100))
        turns.follow(.release(velocity: 0))
        #expect(!turns.isTurning)
        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    // MARK: Scroll events

    /// A scroll event as a trackpad would send it. These are synthetic: none of this has been near
    /// real fingers.
    private func scrollEvent(
        x: Int32 = 0, y: Int32 = 0, phase: Int64 = 0, momentum: Int64 = 0, continuous: Bool = true,
        inverted: Bool = false
    ) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        // The field behind `isDirectionInvertedFromDevice`, which has no public name.
        event.setIntegerValueField(try #require(CGEventField(rawValue: 137)), value: inverted ? 1 : 0)
        return try #require(NSEvent(cgEvent: event))
    }

    private static let began: Int64 = 1
    private static let changed: Int64 = 2
    private static let ended: Int64 = 4
    private static let cancelled: Int64 = 8
    private static let mayBegin: Int64 = 128

    private func desk() -> (DeskView, () -> [SwipeSignal]) {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let desk = DeskView(frame: frame, bookFrame: frame.insetBy(dx: 34, dy: 34))
        final class Box { var signals: [SwipeSignal] = [] }
        let box = Box()
        desk.onSwipe = { box.signals.append($0) }
        return (desk, { box.signals })
    }

    /// Natural scrolling is off in the synthetic events below unless they say otherwise, so fingers
    /// going right to left show as positive deltas.
    @Test func theDeskTurnsForwardForRightToLeftFingersUnderEitherSetting() throws {
        let (natural, naturalSignals) = desk()
        let inverted = try scrollEvent(x: -10, phase: Self.began, inverted: true)
        #expect(inverted.isDirectionInvertedFromDevice)
        natural.scrollWheel(with: inverted)
        #expect(naturalSignals() == [.start(.forward), .move(10)])

        let (traditional, traditionalSignals) = desk()
        let notInverted = try scrollEvent(x: 10, phase: Self.began)
        #expect(!notInverted.isDirectionInvertedFromDevice)
        traditional.scrollWheel(with: notInverted)
        #expect(traditionalSignals() == [.start(.forward), .move(10)])
    }

    @Test func theDeskTurnsBackForLeftToRightFingersUnderEitherSetting() throws {
        let (natural, naturalSignals) = desk()
        natural.scrollWheel(with: try scrollEvent(x: 10, phase: Self.began, inverted: true))
        #expect(naturalSignals() == [.start(.backward), .move(10)])

        let (traditional, traditionalSignals) = desk()
        traditional.scrollWheel(with: try scrollEvent(x: -10, phase: Self.began))
        #expect(traditionalSignals() == [.start(.backward), .move(10)])
    }

    @Test func scrollingGoesToTheDeskOnlyInItsOwnWindowWithNoSheet() {
        #expect(ScrollRoute(isOurWindow: true, hasSheet: false) == .desk)
        // Handed back, normal dispatch could still bring it to the desk.
        #expect(ScrollRoute(isOurWindow: true, hasSheet: true) == .swallow)
        #expect(ScrollRoute(isOurWindow: false, hasSheet: false) == .passOn)
        #expect(ScrollRoute(isOurWindow: false, hasSheet: true) == .passOn)
    }

    /// The open contents scroll their own list, and pages don't turn beside them.
    @Test func theOpenContentsKeepScrollingFromTheDesk() {
        #expect(ScrollRoute(isOurWindow: true, hasSheet: false, contents: .under) == .passOn)
        #expect(ScrollRoute(isOurWindow: true, hasSheet: false, contents: .beside) == .swallow)
        #expect(ScrollRoute(isOurWindow: true, hasSheet: false, contents: .closed) == .desk)
        #expect(ScrollRoute(isOurWindow: true, hasSheet: true, contents: .under) == .swallow)
    }

    @Test func aSyntheticEventCarriesWhatTheDeskReads() throws {
        let event = try scrollEvent(x: -12, y: 3, phase: Self.changed)
        #expect(event.phase == .changed)
        #expect(event.momentumPhase == [])
        #expect(event.scrollingDeltaX == -12)
        #expect(event.scrollingDeltaY == 3)
    }

    @Test func theDeskReadsASwipeFromScrollEvents() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(phase: Self.mayBegin))
        desk.scrollWheel(with: try scrollEvent(x: 10, phase: Self.began))
        desk.scrollWheel(with: try scrollEvent(x: 40, phase: Self.changed))
        desk.scrollWheel(with: try scrollEvent(phase: Self.ended))
        #expect(signals().prefix(3) == [.start(.forward), .move(10), .move(40)])
        #expect(signals().count == 4)
        if case .release = signals().last {} else { Issue.record("Expected a release last") }
    }

    @Test func theDeskIgnoresMomentum() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(x: 10, phase: Self.began))
        desk.scrollWheel(with: try scrollEvent(phase: Self.ended))
        let afterRelease = signals().count
        desk.scrollWheel(with: try scrollEvent(x: 30, momentum: 1))
        desk.scrollWheel(with: try scrollEvent(x: 30, momentum: 2))
        desk.scrollWheel(with: try scrollEvent(x: 30, momentum: 3))
        #expect(signals().count == afterRelease)
    }

    @Test func theDeskIgnoresVerticalScrolls() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(x: 1, y: 10, phase: Self.began))
        desk.scrollWheel(with: try scrollEvent(x: -40, phase: Self.changed))
        desk.scrollWheel(with: try scrollEvent(phase: Self.ended))
        #expect(signals().isEmpty)
    }

    @Test func theDeskIgnoresAMouseWheel() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(x: -50, continuous: false))
        #expect(signals().isEmpty)
    }

    @Test func theDeskPassesOnACancelledGesture() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(x: 10, phase: Self.began))
        desk.scrollWheel(with: try scrollEvent(phase: Self.cancelled))
        #expect(signals().last == .abandon)
    }

    @Test func theDeskCanAbandonASwipeWhoseEndWontReachIt() throws {
        let (desk, signals) = desk()
        desk.scrollWheel(with: try scrollEvent(x: 10, phase: Self.began))
        desk.abandonSwipe()
        desk.scrollWheel(with: try scrollEvent(x: 10, phase: Self.changed))
        #expect(signals() == [.start(.forward), .move(10), .abandon])
    }
}
