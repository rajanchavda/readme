import Testing
@testable import Readme

@Suite struct IdleTimerTests {
    @Test func awakeStraightAfterActivity() {
        var timer = IdleTimer()
        timer.activity(at: 100)
        #expect(timer.isAwake(at: 100))
        #expect(timer.isAwake(at: 101.5))
    }

    @Test func asleepAfterTheDelay() {
        var timer = IdleTimer()
        timer.activity(at: 100)
        #expect(!timer.isAwake(at: 101.6))
        #expect(!timer.isAwake(at: 200))
    }

    @Test func activityWakesItAgain() {
        var timer = IdleTimer()
        timer.activity(at: 100)
        #expect(!timer.isAwake(at: 102))
        timer.activity(at: 102)
        #expect(timer.isAwake(at: 102))
        #expect(timer.isAwake(at: 103))
    }

    @Test func asleepBeforeAnyActivity() {
        #expect(!IdleTimer().isAwake(at: 0))
    }

    @Test func sleepingEndsTheWait() {
        var timer = IdleTimer()
        timer.activity(at: 100)
        timer.sleep()
        #expect(!timer.isAwake(at: 100))
    }
}
