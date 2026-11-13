import Foundation
import Testing
@testable import Readme

@MainActor
private final class Flag {
    var set = false
}

/// `NSApp.terminate` waits in a nested run loop for `applicationShouldTerminate`'s reply, which comes
/// from a main-actor task. These tests wait the same way, without quitting anything.
@MainActor
@Suite struct QuitLaterTests {
    /// Called from inside a main-actor task, as the updater's hand-off is, the action still lets other
    /// main-actor tasks run while it waits. Called straight from the task, it would wait forever.
    @Test func mainActorTasksRunWhileTheActionWaits() async {
        let ran = Flag()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                QuitLater.run {
                    let reply = Flag()
                    Task { @MainActor in reply.set = true }
                    let deadline = Date().addingTimeInterval(2)
                    while !reply.set, Date() < deadline {
                        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                    }
                    ran.set = reply.set
                    done.resume()
                }
            }
        }
        #expect(ran.set)
    }
}
