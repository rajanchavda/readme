import AppKit
import OSLog
import QuartzCore

/// The arithmetic of one turn's frames, from a display link's clock.
///
/// `missed` is display refreshes that passed with no tick, seen from a jump in the link's timestamps.
/// `late` counts apart from it the ticks and poses that happened after the moment their frame was due.
/// It isn't a missed frame by itself: whole turns have run a steady millisecond behind their targets with
/// the same cadence and no more real drops, so it's a sign of pressure, read alongside `missed`.
///
/// All of this sees only this process. A frame that left here on time and was then dropped by the render
/// server isn't in these numbers: see docs/curl-trial.md.
struct CurlFrameTally {
    /// Display refreshes covered, from the first tick to the last.
    private(set) var frames = 0
    private(set) var missed = 0
    private(set) var late = 0
    /// The longest gap between ticks, in seconds.
    private(set) var longest = 0.0
    /// Seconds to spare on the pose nearest its target. Below zero means it arrived after it.
    private(set) var tightestMargin = Double.infinity
    private(set) var refreshRate = 0.0

    private var lastTimestamp: Double?
    private var lastLateTarget: Double?

    mutating func tick(timestamp: Double, target: Double, now: Double) {
        let period = target - timestamp
        guard period > 0 else { return }
        refreshRate = 1 / period
        if let lastTimestamp {
            let gap = timestamp - lastTimestamp
            let refreshes = max(1, Int((gap / period).rounded()))
            frames += refreshes
            missed += refreshes - 1
            longest = max(longest, gap)
        }
        lastTimestamp = timestamp
        if now >= target { markLate(target) }
    }

    /// A pose for the frame due at `target` has just reached Core Animation.
    mutating func posed(target: Double, now: Double) {
        tightestMargin = min(tightestMargin, target - now)
        if now >= target { markLate(target) }
    }

    /// The display link behind a turn and this monitor's own tick for the same refresh, so one frame
    /// can't count twice.
    private mutating func markLate(_ target: Double) {
        guard target != lastLateTarget else { return }
        lastLateTarget = target
        late += 1
    }
}

/// What the monitor found over one turn.
struct CurlFrameSummary {
    let direction: TurnDirection
    /// True if fingers moved the page, rather than it only playing.
    let isFollowed: Bool
    let tally: CurlFrameTally
    /// How long the turn was on screen, from the first tick to the last, in seconds.
    let duration: Double
    /// From starting to set the turn up to its first frame, in seconds. A delay, not a stutter: the
    /// curl's clock starts on that frame.
    let startDelay: Double
    /// The longest time one pose took on this thread, in seconds.
    let longestPose: Double
}

/// Measures each turn while it's on screen and logs its longest frame and missed frames.
///
/// It has its own display link because a held page has none: only fingers move it. It runs only while
/// a turn is showing, and costs a few additions a frame. Logged at debug level, which only shows when
/// asked for, so numbers appear with:
///
///     /usr/bin/log stream --level debug --predicate 'subsystem == "com.rajanchavda.Readme" AND category == "CurlFrames"'
@MainActor
final class CurlFrameMonitor: NSObject {
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "CurlFrames")

    /// Hears each turn's summary as it's logged.
    var onSummary: ((CurlFrameSummary) -> Void)?

    private var link: CADisplayLink?
    private var direction = TurnDirection.forward
    private var tally = CurlFrameTally()
    private var setUpTime = 0.0
    private var firstTarget: Double?
    private var lastTimestamp = 0.0
    private var firstTimestamp = 0.0
    private var longestPose = 0.0
    private var heldPoses = 0

    /// `setUpTime` is when work on this turn began, on the `CACurrentMediaTime` clock.
    func start(on view: NSView, direction: TurnDirection, setUpTime: Double) {
        stop()
        self.direction = direction
        self.setUpTime = setUpTime
        tally = CurlFrameTally()
        firstTarget = nil
        longestPose = 0
        heldPoses = 0
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Notes a pose, which took from `started` until now. `target` is the frame it's for, and nil for
    /// one that follows fingers, which isn't aimed at any frame.
    func posed(started: Double, target: Double?) {
        guard link != nil else { return }
        let now = CACurrentMediaTime()
        longestPose = max(longestPose, now - started)
        if let target {
            tally.posed(target: target, now: now)
        } else {
            heldPoses += 1
        }
    }

    /// Ends the turn being measured and reports it. It's fine to call this with none.
    func stop() {
        guard let finished = link else { return }
        finished.invalidate()
        link = nil
        let summary = CurlFrameSummary(
            direction: direction,
            isFollowed: heldPoses > 1,
            tally: tally,
            duration: firstTarget == nil ? 0 : lastTimestamp - firstTimestamp,
            startDelay: firstTarget.map { $0 - setUpTime } ?? 0,
            longestPose: longestPose)
        report(summary)
        onSummary?(summary)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        if firstTarget == nil {
            firstTarget = target
            firstTimestamp = link.timestamp
        }
        lastTimestamp = link.timestamp
        tally.tick(timestamp: link.timestamp, target: target, now: CACurrentMediaTime())
    }

    private func report(_ summary: CurlFrameSummary) {
        let tally = summary.tally
        let margin = tally.tightestMargin.isFinite ? tally.tightestMargin * 1000 : 0
        Self.log.debug("""
            turn \(summary.direction == .forward ? "forward" : "backward", privacy: .public) \
            \(summary.isFollowed ? "followed" : "played", privacy: .public): \
            frames \(tally.frames) at \(tally.refreshRate, format: .fixed(precision: 0)) Hz, \
            longest \(tally.longest * 1000, format: .fixed(precision: 1)) ms, \
            missed \(tally.missed), late \(tally.late), \
            tightest pose margin \(margin, format: .fixed(precision: 1)) ms, \
            longest pose \(summary.longestPose * 1000, format: .fixed(precision: 1)) ms, \
            start delay \(summary.startDelay * 1000, format: .fixed(precision: 0)) ms, \
            on screen \(summary.duration * 1000, format: .fixed(precision: 0)) ms
            """)
    }
}
