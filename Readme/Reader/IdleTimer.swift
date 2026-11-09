import Foundation

/// Whether the reader has moved the mouse lately, which is when the toolbar shows. Times are in
/// seconds, from any one clock.
struct IdleTimer {
    var delay: TimeInterval = 1.6
    private var lastActivity: TimeInterval?

    mutating func activity(at time: TimeInterval) {
        lastActivity = time
    }

    /// Asleep at once, as when the mouse leaves the window.
    mutating func sleep() {
        lastActivity = nil
    }

    func isAwake(at time: TimeInterval) -> Bool {
        guard let lastActivity else { return false }
        // Not `time - lastActivity`, which can fall a rounding error short of `delay` when it's up.
        return time < lastActivity + delay
    }
}
