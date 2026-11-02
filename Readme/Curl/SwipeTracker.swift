import Foundation

enum SwipeOutcome {
    case commit, cancel
}

/// How far fingers have carried a page, and whether it goes over when they let go.
///
/// It knows nothing of which way the page is turning: distances and speeds are positive towards
/// turning it, and progress runs from 0 where it lies at the start to 1 where it's gone over.
struct SwipeTracker {
    /// A release faster than this, in points per second, decides the turn by its direction.
    private static let flickSpeed = 600.0

    private let pageWidth: Double
    /// Kept within the page, so fingers that went past an end move the page as soon as they turn back.
    private var distance = 0.0

    var progress: Double { distance / pageWidth }

    init(pageWidth: Double) {
        self.pageWidth = pageWidth
    }

    mutating func began() {
        distance = 0
    }

    mutating func changed(deltaX: Double) -> Double {
        distance = min(pageWidth, max(0, distance + deltaX))
        return progress
    }

    mutating func ended(velocityX: Double) -> SwipeOutcome {
        if velocityX > Self.flickSpeed { return .commit }
        if velocityX < -Self.flickSpeed { return .cancel }
        return progress >= 0.5 ? .commit : .cancel
    }
}

/// What a scroll gesture amounts to for the page. Distances and speeds are positive towards turning it.
enum SwipeSignal: Equatable {
    case start(TurnDirection)
    case move(Double)
    case release(velocity: Double)
    /// The gesture stopped without the fingers letting go, so the page should fall back.
    case abandon
}

/// Reads one scroll gesture at a time, deciding early whether it's a swipe across the page and which
/// way, and ignoring it from then on if it isn't.
///
/// Fingers moving right to left make negative deltas under natural scrolling, and they turn forward.
/// The deltas are used as given, so a reader with natural scrolling off turns the other way, the way
/// their scrolling goes.
struct SwipeGesture {
    enum Phase {
        case began, changed, ended, cancelled
    }

    private enum State {
        case idle
        case deciding(x: Double, y: Double)
        case ignoring
        case following(TurnDirection)
    }

    /// Finger travel, in points, by which the axis is decided. Enough to tell what a gesture is, and
    /// too little for the reader to notice the page hasn't moved yet.
    private static let decisionDistance = 8.0
    /// How far back the release speed looks, in seconds.
    private static let speedWindow = 0.1

    private var state = State.idle
    private var recent: [(time: Double, deltaX: Double)] = []

    /// The events of a gesture, in order. Those with no beginning are ignored.
    mutating func handle(_ phase: Phase, deltaX: Double, deltaY: Double, at time: Double) -> [SwipeSignal] {
        switch phase {
        case .began:
            let signals = abandon()
            state = .deciding(x: 0, y: 0)
            recent = []
            return signals + travel(deltaX: deltaX, deltaY: deltaY, at: time)
        case .changed:
            return travel(deltaX: deltaX, deltaY: deltaY, at: time)
        case .ended:
            var signals = travel(deltaX: deltaX, deltaY: deltaY, at: time)
            if case let .following(direction) = state {
                signals.append(.release(velocity: along(direction, speed(at: time))))
            }
            state = .idle
            return signals
        case .cancelled:
            return abandon()
        }
    }

    /// Forgets the gesture, whatever more arrives of it.
    mutating func abandon() -> [SwipeSignal] {
        defer { state = .idle }
        if case .following = state { return [.abandon] }
        return []
    }

    private mutating func travel(deltaX: Double, deltaY: Double, at time: Double) -> [SwipeSignal] {
        recent.removeAll { $0.time < time - Self.speedWindow }
        recent.append((time, deltaX))
        switch state {
        case .idle, .ignoring:
            return []
        case let .following(direction):
            return deltaX == 0 ? [] : [.move(along(direction, deltaX))]
        case let .deciding(x, y):
            let x = x + deltaX, y = y + deltaY
            guard max(abs(x), abs(y)) >= Self.decisionDistance else {
                state = .deciding(x: x, y: y)
                return []
            }
            guard abs(x) > abs(y) else {
                state = .ignoring
                return []
            }
            let direction = x < 0 ? TurnDirection.forward : .backward
            state = .following(direction)
            return [.start(direction), .move(along(direction, x))]
        }
    }

    /// Between the first and last events kept, in `deltaX` terms. The first event's distance was
    /// covered before its time, so it doesn't count.
    private func speed(at time: Double) -> Double {
        guard let first = recent.first, time > first.time else { return 0 }
        return recent.dropFirst().reduce(0) { $0 + $1.deltaX } / (time - first.time)
    }

    private func along(_ direction: TurnDirection, _ deltaX: Double) -> Double {
        direction == .forward ? -deltaX : deltaX
    }
}
