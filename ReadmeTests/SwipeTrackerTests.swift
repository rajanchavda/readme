import Foundation
import Testing
@testable import Readme

@Suite struct SwipeTrackerTests {
    /// A tracker that's been swiped to `progress` of its 500-point page.
    private func tracker(at progress: Double) -> SwipeTracker {
        var tracker = SwipeTracker(pageWidth: 500)
        tracker.began()
        _ = tracker.changed(deltaX: progress * 500)
        return tracker
    }

    // MARK: Required by the plan

    @Test func followsFingers() {
        var tracker = SwipeTracker(pageWidth: 500)
        tracker.began()
        #expect(tracker.changed(deltaX: 100) == 0.2)
        #expect(tracker.changed(deltaX: 150) == 0.5)
    }

    @Test func clampsAtEnds() {
        var tracker = SwipeTracker(pageWidth: 500)
        tracker.began()
        #expect(tracker.changed(deltaX: 1000) == 1)

        tracker.began()
        #expect(tracker.changed(deltaX: -1000) == 0)
    }

    @Test func commitsPastHalfway() {
        var swipe = tracker(at: 0.6)
        #expect(swipe.ended(velocityX: 0) == .commit)
    }

    @Test func fallsBackBeforeHalfway() {
        var swipe = tracker(at: 0.3)
        #expect(swipe.ended(velocityX: 0) == .cancel)
    }

    @Test func flickCommits() {
        var swipe = tracker(at: 0.2)
        #expect(swipe.ended(velocityX: 601) == .commit)
    }

    @Test func reverseFlickCancels() {
        var swipe = tracker(at: 0.7)
        #expect(swipe.ended(velocityX: -601) == .cancel)
    }

    // MARK: Around those

    @Test func aSlowerMoveIsNotAFlick() {
        var early = tracker(at: 0.2)
        #expect(early.ended(velocityX: 600) == .cancel)
        var late = tracker(at: 0.7)
        #expect(late.ended(velocityX: -600) == .commit)
    }

    /// Fingers that went past the end move the page as soon as they turn back.
    @Test func comingBackFromAnEndMovesAtOnce() {
        var tracker = SwipeTracker(pageWidth: 500)
        tracker.began()
        _ = tracker.changed(deltaX: 1000)
        #expect(tracker.changed(deltaX: -50) == 0.9)
    }

    @Test func beganStartsAgain() {
        var swipe = tracker(at: 0.7)
        swipe.began()
        #expect(swipe.progress == 0)
        #expect(swipe.changed(deltaX: 50) == 0.1)
    }
}

@Suite struct SwipeGestureTests {
    /// Sends one event, at a sixtieth of a second per step.
    private func send(
        _ gesture: inout SwipeGesture, _ phase: SwipeGesture.Phase, x: Double = 0, y: Double = 0, step: Int = 0
    ) -> [SwipeSignal] {
        gesture.handle(phase, deltaX: x, deltaY: y, at: Double(step) / 60)
    }

    @Test func fingersRightToLeftTurnForward() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .began, x: -3).isEmpty)
        #expect(send(&gesture, .changed, x: -3, step: 1).isEmpty)
        // Decided: all the distance so far counts, as the page is under the fingers from the start.
        #expect(send(&gesture, .changed, x: -3, step: 2) == [.start(.forward), .move(9)])
        #expect(send(&gesture, .changed, x: -5, step: 3) == [.move(5)])
        #expect(send(&gesture, .changed, x: 2, step: 4) == [.move(-2)])
    }

    @Test func fingersLeftToRightTurnBack() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .began, x: 10) == [.start(.backward), .move(10)])
        #expect(send(&gesture, .changed, x: 4, step: 1) == [.move(4)])
        #expect(send(&gesture, .changed, x: -1, step: 2) == [.move(-1)])
    }

    @Test func aMostlyVerticalScrollIsIgnoredToTheEnd() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .began, x: 2, y: 9).isEmpty)
        // Later sideways movement can't take it over once the axis is decided.
        #expect(send(&gesture, .changed, x: -200, step: 1).isEmpty)
        #expect(send(&gesture, .ended, step: 2).isEmpty)
    }

    @Test func aDiagonalScrollIsIgnored() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .began, x: 10, y: 10).isEmpty)
        #expect(send(&gesture, .changed, x: 100, step: 1).isEmpty)
    }

    @Test func aTouchTooSmallToDecideDoesNothing() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .began, x: -3).isEmpty)
        #expect(send(&gesture, .ended, step: 1).isEmpty)
    }

    @Test func aReleaseCarriesTheFingersSpeed() throws {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        for step in 1...3 { _ = send(&gesture, .changed, x: -20, step: step) }
        // 60 points in the four steps since the first event, whose own distance came before it.
        let signals = send(&gesture, .ended, step: 4)
        guard case let .release(velocity) = try #require(signals.first) else {
            Issue.record("Expected a release")
            return
        }
        #expect(abs(velocity - 900) < 1)
    }

    @Test func aReleaseBackwardsReadsAsAReverseVelocity() throws {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        for step in 1...3 { _ = send(&gesture, .changed, x: 20, step: step) }
        guard case let .release(velocity) = try #require(send(&gesture, .ended, step: 3).first) else {
            Issue.record("Expected a release")
            return
        }
        #expect(abs(velocity + 1200) < 1)
    }

    /// Holding the page still before letting go isn't a flick, however fast it got there.
    @Test func aPauseBeforeReleaseHasNoSpeed() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        _ = send(&gesture, .changed, x: -20, step: 1)
        #expect(send(&gesture, .ended, step: 30) == [.release(velocity: 0)])
    }

    @Test func oneEventHasNoSpeedToSpeakOf() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        #expect(send(&gesture, .ended, step: 0) == [.release(velocity: 0)])
    }

    @Test func distanceOnTheLastEventStillCounts() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        #expect(send(&gesture, .ended, x: -5, step: 30) == [.move(5), .release(velocity: 0)])
    }

    @Test func aCancelledGestureAbandons() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        #expect(send(&gesture, .cancelled, step: 1) == [.abandon])
        #expect(send(&gesture, .changed, x: -20, step: 2).isEmpty)
    }

    @Test func abandoningMidSwipeSaysSoOnce() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        #expect(gesture.abandon() == [.abandon])
        #expect(gesture.abandon().isEmpty)
    }

    @Test func nothingHappensWithoutABeginning() {
        var gesture = SwipeGesture()
        #expect(send(&gesture, .changed, x: -200).isEmpty)
        #expect(send(&gesture, .ended, step: 1).isEmpty)
        #expect(send(&gesture, .cancelled, step: 2).isEmpty)
    }

    /// An end that never came mustn't leave the old swipe holding the page.
    @Test func aNewGestureAbandonsOneThatNeverEnded() {
        var gesture = SwipeGesture()
        _ = send(&gesture, .began, x: -20)
        #expect(send(&gesture, .began, x: 20, step: 1) == [.abandon, .start(.backward), .move(20)])
    }
}
