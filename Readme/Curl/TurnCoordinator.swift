import AppKit
import WebKit

/// The four pages a curl needs, cut from whole spreads. `target` is the spread being turned to.
struct TurnImages {
    let front: CGImage
    let back: CGImage
    let beneathLeft: CGImage
    let beneathRight: CGImage

    init?(_ direction: TurnDirection, current: CGImage, target: CGImage) {
        guard let currentLeft = Self.half(of: current, right: false),
              let currentRight = Self.half(of: current, right: true),
              let targetLeft = Self.half(of: target, right: false),
              let targetRight = Self.half(of: target, right: true)
        else { return nil }
        switch direction {
        case .forward:
            front = currentRight
            back = targetLeft
            beneathLeft = currentLeft
            beneathRight = targetRight
        case .backward:
            front = targetRight
            back = currentLeft
            beneathLeft = targetLeft
            beneathRight = currentRight
        }
    }

    private static func half(of spread: CGImage, right: Bool) -> CGImage? {
        let leftWidth = spread.width / 2
        return spread.cropping(to: CGRect(
            x: right ? leftWidth : 0, y: 0,
            width: right ? spread.width - leftWidth : leftWidth, height: spread.height))
    }
}

/// What a curl shows: four pages cut from two spreads, or, with one page across, the page that turns
/// and the one beneath it.
enum CurlPieces {
    case spread(TurnImages)
    case page(front: CGImage, beneath: CGImage)

    init?(_ direction: TurnDirection, current: CGImage, target: CGImage, isSinglePage: Bool) {
        if isSinglePage {
            // Going back is the forward turn played in reverse, so the page coming back is the one
            // that turns.
            self = direction == .forward
                ? .page(front: current, beneath: target) : .page(front: target, beneath: current)
        } else {
            guard let images = TurnImages(direction, current: current, target: target) else { return nil }
            self = .spread(images)
        }
    }
}

/// Turns the pages of a book: it plays the curl over the web view and moves the web view beneath it.
///
/// The curl only ever uses images known to belong to where the book is. A press that outruns them
/// waits only briefly, then the page just changes with no curl, as it does if another press arrives
/// first, so every press counts and the book never seems to ignore one.
///
/// A swipe holds the same curl under the reader's fingers, with the web view staying where it is until
/// they let go past the point of turning. It always turns with the curl. Its images can still be on
/// their way, as just after a jump: then the curl rises to meet the fingers as soon as they come, or,
/// if the fingers let go to turn before then, plays the whole turn once they come. A press while the
/// fingers are down counts as them letting go, standing still, so what's held always ends the same
/// way and keys can't stop working.
@MainActor
final class TurnCoordinator {
    /// How long a press waits for images before the page changes without a curl. A page takes about
    /// another 120 ms to move, so this is what keeps a press from looking ignored.
    static let defaultPatience: Duration = .milliseconds(50)
    /// How long a press waits for the move before it to land, which is usually about 120 ms.
    private static let landingPatience: Duration = .milliseconds(150)
    private static let paintTimeout: Duration = .milliseconds(500)
    /// How often a swipe looks for its images.
    private static let swipePollInterval: Duration = .milliseconds(10)
    /// How long a swipe that's let go to turn waits for its images. The furthest spread a jump has to
    /// make takes about a second and a half on a long book, so this is only for images that never come.
    static let swipePatience: Duration = .milliseconds(2500)
    /// How long a curl whose images came after the fingers began takes to rise to meet them.
    private static let catchUpDuration = 0.15

    /// A swipe with the fingers down.
    private struct Swipe {
        let direction: TurnDirection
        var tracker: SwipeTracker
        var isCurling = false
        /// The curl is still rising to where the fingers are, so it doesn't follow them yet.
        var isCatchingUp = false

        /// Going back is the forward curl played from its end.
        var curlProgress: Double {
            direction == .forward ? tracker.progress : 1 - tracker.progress
        }
    }

    private let book: BookWebView
    private let cache: SpreadCache
    private let curl: CurlView
    private let reduceMotion: () -> Bool
    private let patience: Duration
    private let takeSnapshot: (WKSnapshotConfiguration, @escaping () -> Void) -> Void

    /// Moves of the book that haven't finished settling.
    private var moves = 0
    /// Moves that haven't landed. Until they have, the cache's images and the location are out of date.
    private var unlanded = 0
    private var waitingTurn: TurnDirection?
    private var waitingTask: Task<Void, Never>?
    /// Identifies the latest curl, so an earlier one's landing doesn't remove it.
    private var curlNumber = 0
    private var swipe: Swipe?
    private var swipeWait: Task<Void, Never>?
    private var catchUp: Task<Void, Never>?
    /// The moves and jumps that haven't finished, by number. A jump waits for them.
    private var underWay: [Int: Task<Void, Never>] = [:]
    private var moveNumber = 0
    /// The latest jump, which moves asked for after it wait for.
    private var jumping: Task<Void, Never>?
    /// Links in the book followed and not yet landed, and the jumps waiting for them to.
    private var linksLanding = 0
    private var linkWaiters: [CheckedContinuation<Void, Never>] = []

    /// The paper's colour, which the back of a single turning page shows.
    var pageColor = CGColor(gray: 1, alpha: 1)

    /// True from a turn being accepted until the web view shows where it landed.
    var isTurning: Bool { swipe != nil || waitingTurn != nil || moves > 0 || curl.isShowing }

    init(
        book: BookWebView, cache: SpreadCache, curl: CurlView,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        patience: Duration = TurnCoordinator.defaultPatience,
        takeSnapshot: ((WKSnapshotConfiguration, @escaping () -> Void) -> Void)? = nil
    ) {
        self.book = book
        self.cache = cache
        self.curl = curl
        self.reduceMotion = reduceMotion
        self.patience = patience
        self.takeSnapshot = takeSnapshot ?? { [weak book] configuration, finished in
            guard let webView = book?.webView else { return finished() }
            webView.takeSnapshot(with: configuration) { _, _ in finished() }
        }
        cache.onUnforeseenMove = { [weak self] in self?.bookMovedElsewhere() }
        book.addLinkListener { [weak self] landed in
            if landed { self?.linkLanded() } else { self?.linkFollowed() }
        }
    }

    /// `isRepeat` is a held key's repeat. Pages stop when the key is let go, so a repeat is dropped,
    /// never kept for later, while a turn before it is waiting for its images or its move to land,
    /// which also covers a curl that's just started. Every other press counts.
    func turn(_ direction: TurnDirection, isRepeat: Bool = false) {
        guard book.currentLocation != nil else { return }
        if isRepeat && (unlanded > 0 || waitingTurn != nil) { return }
        finishEarlierTurns()
        if unlanded == 0, startOrDecline(direction) { return }
        waitingTurn = direction
        waitingTask = Task { [weak self] in await self?.waitAndTurn(direction) }
    }

    /// Returns once the turns and jumps asked for so far have moved the book: a turn waiting for its
    /// images makes its move, then every move under way lands and settles. A page still held by the
    /// fingers isn't a turn yet.
    func landed() async {
        await waitingTask?.value
        for move in Array(underWay.values) { await move.value }
    }

    /// Follows the fingers. What arrives with no swipe to act on, such as the rest of a gesture whose
    /// swipe a press has ended, is ignored.
    func follow(_ signal: SwipeSignal) {
        switch signal {
        case let .start(direction):
            startSwipe(direction)
        case let .move(distance):
            _ = swipe?.tracker.changed(deltaX: distance)
            if let swipe, swipe.isCurling, !swipe.isCatchingUp { curl.setProgress(swipe.curlProgress) }
        case let .release(velocity):
            guard let outcome = swipe?.tracker.ended(velocityX: velocity) else { return }
            finishSwipe(outcome)
        case .abandon:
            finishSwipe(.cancel)
        }
    }

    /// Whatever's under way has to end before anything new can begin.
    private func finishEarlierTurns() {
        // As if the fingers let go where they are, not moving.
        if var held = swipe { finishSwipe(held.tracker.ended(velocityX: 0)) }
        curl.snapToEnd()
        if let earlier = waitingTurn {
            // It's been overtaken, so it has its move now and no curl.
            waitingTask?.cancel()
            waitingTurn = nil
            _ = move(earlier)
        }
    }

    private func startSwipe(_ direction: TurnDirection) {
        guard book.currentLocation != nil else { return }
        finishEarlierTurns()
        var tracker = SwipeTracker(pageWidth: isSinglePage ? curl.bounds.width : curl.bounds.width / 2)
        tracker.began()
        swipe = Swipe(direction: direction, tracker: tracker)
        if pickUpSwipe() { return }
        // The images the fingers need are rendered first.
        cache.prefer(direction)
        // Waits on nothing but the fingers, so it mustn't keep this object alive if they never lift.
        swipeWait = Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.swipePollInterval)
                guard !Task.isCancelled, let self, !self.pickUpSwipe(late: true) else { return }
            }
        }
    }

    /// True if the swipe needs no more waiting: its curl is on screen, it never has one, or it's past
    /// the end of the book and so over. The images can only be trusted with nothing left to land.
    private func pickUpSwipe(late: Bool = false) -> Bool {
        guard let held = swipe, unlanded == 0 else { return false }
        if isPastTheEnd(held.direction) {
            swipe = nil
            return true
        }
        if reduceMotion() { return true }
        guard let spreads = images(for: held.direction),
              let pieces = CurlPieces(
                held.direction, current: spreads.current, target: spreads.target, isSinglePage: isSinglePage)
        else { return false }
        // An earlier curl still waiting to come off must leave this one be.
        curlNumber += 1
        begin(held.direction, pieces)
        swipe?.isCurling = true
        if late {
            riseToFingers(from: held.direction == .forward ? 0 : 1)
        } else {
            curl.setProgress(held.curlProgress)
        }
        return true
    }

    /// The fingers are already partway across, so the curl eases up to them rather than appearing
    /// there, then follows them as usual.
    private func riseToFingers(from start: Double) {
        swipe?.isCatchingUp = true
        curl.setProgress(start)
        catchUp = Task { [weak self] in
            let began = ContinuousClock.now
            while !Task.isCancelled {
                guard let self, let held = self.swipe, held.isCatchingUp else { return }
                let elapsed = began.duration(to: .now) / .seconds(1)
                let share = min(1, elapsed / Self.catchUpDuration)
                let eased = 1 - (1 - share) * (1 - share)
                self.curl.setProgress(start + (held.curlProgress - start) * eased)
                if share >= 1 {
                    self.swipe?.isCatchingUp = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private func finishSwipe(_ outcome: SwipeOutcome) {
        guard let held = swipe else { return }
        swipe = nil
        swipeWait?.cancel()
        swipeWait = nil
        catchUp?.cancel()
        catchUp = nil
        guard held.isCurling else {
            if outcome == .commit { turnWithoutFollowing(held.direction) }
            return
        }
        // The page's already under the curl, so this is the one moment it may move.
        let landing = outcome == .commit ? move(held.direction) : nil
        curlNumber += 1
        let number = curlNumber
        let wentOver = held.direction == .forward ? outcome == .commit : outcome == .cancel
        curl.play(from: curl.progress, to: wentOver ? 1 : 0) { [weak self] in
            self?.uncover(curl: number, after: landing)
        }
        CATransaction.flush()
    }

    /// Fingers have let go past the point of turning before their curl's images came. The turn waits
    /// for them, longer than a press does, and plays the whole curl as soon as they're here: a swipe
    /// always turns with the curl. Images that never come leave the page to change without one.
    private func turnWithoutFollowing(_ direction: TurnDirection) {
        if reduceMotion() {
            turn(direction)
            return
        }
        if unlanded == 0, startOrDecline(direction) { return }
        cache.prefer(direction)
        waitingTurn = direction
        waitingTask = Task { [weak self] in await self?.waitAndTurn(direction, patience: Self.swipePatience) }
    }

    /// The book's laid out one page across. Its images then hold one page each, as they're made in
    /// the same layout.
    private var isSinglePage: Bool { book.columns == 1 }

    private func begin(_ direction: TurnDirection, _ pieces: CurlPieces) {
        switch pieces {
        case let .spread(images):
            curl.begin(
                direction, front: images.front, back: images.back,
                beneathLeft: images.beneathLeft, beneathRight: images.beneathRight)
        case let .page(front, beneath):
            curl.beginPage(direction, front: front, beneath: beneath, blank: pageColor)
        }
    }

    private func isPastTheEnd(_ direction: TurnDirection) -> Bool {
        guard let here = book.currentLocation else { return true }
        return direction == .forward ? here.isAtEnd : here.isAtStart
    }

    /// The spreads a turn goes from and to. Every curl and crossfade gets its images here, and only
    /// gets them if they belong to where the book is now: a link or a jump can move it without a turn.
    private func images(for direction: TurnDirection) -> (current: CGImage, target: CGImage)? {
        guard let here = book.currentLocation, cache.imagesBelong(to: here),
              let current = cache.image(for: .current),
              let target = cache.image(for: direction == .forward ? .next : .previous)
        else { return nil }
        return (current, target)
    }

    /// The book went somewhere no turn took it, so a curl on screen shows where it was. It comes off,
    /// and fingers holding a page have to start again. A swipe still waiting for its images can carry
    /// on, as it'll get the new place's.
    private func bookMovedElsewhere() {
        if swipe?.isCurling == true {
            swipe = nil
            swipeWait?.cancel()
            swipeWait = nil
        }
        guard curl.isShowing else { return }
        // So the landing of the curl that's going doesn't uncover anything.
        curlNumber += 1
        curl.end()
    }

    /// Waits for a move still landing, as its images will be good then, and briefly for images that
    /// may be about to arrive. Checks repeatedly because the cache has no event to wait on that can
    /// also be given up on.
    private func waitAndTurn(_ direction: TurnDirection, patience: Duration? = nil) async {
        let pressed = ContinuousClock.now
        let patience = patience ?? self.patience
        while true {
            let isWaitingUsefully = unlanded > 0
                ? ContinuousClock.now < pressed + max(Self.landingPatience, patience)
                : images(for: direction) == nil && !isPastTheEnd(direction) && ContinuousClock.now < pressed + patience
            guard isWaitingUsefully else { break }
            try? await Task.sleep(for: .milliseconds(10))
            if Task.isCancelled { return }
        }
        waitingTurn = nil
        if unlanded == 0, startOrDecline(direction) { return }
        _ = move(direction)
    }

    /// True if that settles the turn: it's past the end of the book, or its curl has started. Only
    /// call this with nothing left to land, when the location and images can be trusted.
    private func startOrDecline(_ direction: TurnDirection) -> Bool {
        if isPastTheEnd(direction) { return true }
        guard let spreads = images(for: direction) else { return false }
        start(direction, current: spreads.current, target: spreads.target)
        return true
    }

    private func start(_ direction: TurnDirection, current: CGImage, target: CGImage) {
        let fades = reduceMotion()
        let pieces = CurlPieces(direction, current: current, target: target, isSinglePage: isSinglePage)
        // The move starts after this function, by which time the curl is on its way to the screen.
        let landing = move(direction)
        guard fades || pieces != nil else { return }

        curlNumber += 1
        let number = curlNumber
        let played = { [weak self] in self?.uncover(curl: number, after: landing) ?? () }
        if fades {
            curl.crossfade(from: current, to: target, completion: played)
        } else if let pieces {
            begin(direction, pieces)
            curl.play(
                from: direction == .forward ? 0 : 1, to: direction == .forward ? 1 : 0, completion: played)
        }
        // Covers the web view before it can change. WebKit's layer updates arrive on this thread, so
        // they can't overtake this.
        CATransaction.flush()
    }

    /// The web view's move. They reach the book in the order they're made, and after any jump made
    /// before them.
    private func move(_ direction: TurnDirection) -> Task<Void, Never> {
        moves += 1
        unlanded += 1
        let jump = jumping
        let number = nextMoveNumber()
        let task = Task { [weak self, cache] in
            await jump?.value
            await cache.commit(direction, onLanded: { self?.unlanded -= 1 })
            self?.moves -= 1
            self?.underWay[number] = nil
        }
        underWay[number] = task
        return task
    }

    private func nextMoveNumber() -> Int {
        moveNumber += 1
        return moveNumber
    }

    /// Takes the book somewhere turning doesn't, such as a chapter or a page number, with no curl.
    /// `go` makes the move and returns where it landed, or nil if it went nowhere.
    ///
    /// What's under way ends first, as for a press: a held page is let go and a curl is snapped to its
    /// end. The jump then waits for every turn before it to land and settle, so the cache takes it for
    /// a move it didn't make, renders the new place, and takes the curl off. Otherwise the curl would
    /// play out over the jump's place. Turns asked for meanwhile wait for the jump and turn from where
    /// it lands, with no curl until that place's images are ready.
    func jump(_ go: @escaping () async -> ReaderLocation?) async -> ReaderLocation? {
        await startJump(go)?.value
    }

    /// Starts the jump at once, so a press straight after it waits for it. Nil if there's no book.
    private func startJump(_ go: @escaping () async -> ReaderLocation?) -> Task<ReaderLocation?, Never>? {
        guard book.currentLocation != nil else { return nil }
        finishEarlierTurns()
        let earlier = Array(underWay.values)
        moves += 1
        unlanded += 1
        let number = nextMoveNumber()
        let jump = Task { [weak self] () -> ReaderLocation? in
            for move in earlier { await move.value }
            let landed = await go()
            self?.unlanded -= 1
            self?.moves -= 1
            self?.underWay[number] = nil
            return landed
        }
        let done = Task { _ = await jump.value }
        underWay[number] = done
        jumping = done
        return jump
    }

    /// A link in the book waits in the page's queue, perhaps behind a restyle, and the book still shows
    /// the old place until it lands. It's a jump the coordinator didn't make: no curl starts from the
    /// old place's images meanwhile, and turns pressed meanwhile turn from where it lands.
    private func linkFollowed() {
        linksLanding += 1
        _ = startJump { [weak self] in
            await self?.linksLanded()
            return self?.book.currentLocation
        }
    }

    private func linkLanded() {
        linksLanding = max(0, linksLanding - 1)
        guard linksLanding == 0 else { return }
        let waiters = linkWaiters
        linkWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func linksLanded() async {
        guard linksLanding > 0 else { return }
        await withCheckedContinuation { linkWaiters.append($0) }
    }

    /// Waits for the web view to have the landed page on screen, then uncovers it.
    private func uncover(curl number: Int, after landing: Task<Void, Never>?) {
        Task { [weak self] in
            await landing?.value
            await self?.pagePainted()
            guard let self, number == self.curlNumber else { return }
            self.curl.end()
        }
    }

    /// A snapshot that waits for screen updates only returns once they've reached this process, and
    /// a one-pixel one costs almost nothing. If it never returns, waiting longer won't help: the book
    /// is better uncovered, as the page beneath has landed by now.
    private func pagePainted() async {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        configuration.snapshotWidth = 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = OneShot(continuation)
            takeSnapshot(configuration) { wait.finish() }
            Task {
                try? await Task.sleep(for: Self.paintTimeout)
                wait.finish()
            }
        }
    }
}

/// Finishes a wait once, whichever of its endings comes first.
@MainActor
final class OneShot {
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
