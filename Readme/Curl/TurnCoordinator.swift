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

/// Turns the pages of a book: it plays the curl over the web view and moves the web view beneath it.
///
/// The curl only ever uses images known to belong to where the book is. Without them a turn waits a
/// moment for them, and if they don't come, or another press arrives first, the page just changes
/// with no curl, so every press counts and input never queues up behind the animation.
@MainActor
final class TurnCoordinator {
    private let book: BookWebView
    private let cache: SpreadCache
    private let curl: CurlView
    private let reduceMotion: () -> Bool
    private let patience: Duration

    /// Moves of the book that haven't finished. Until they have, the cache's images may be stale
    /// and the location may not be final.
    private var moves = 0
    private var waitingTurn: TurnDirection?
    private var waitingTask: Task<Void, Never>?
    /// Identifies the latest curl, so an earlier one's landing doesn't remove it.
    private var curlNumber = 0

    /// True from a turn being accepted until the web view shows where it landed.
    var isTurning: Bool { waitingTurn != nil || moves > 0 || curl.isShowing }

    init(
        book: BookWebView, cache: SpreadCache, curl: CurlView,
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        patience: Duration = .milliseconds(750)
    ) {
        self.book = book
        self.cache = cache
        self.curl = curl
        self.reduceMotion = reduceMotion
        self.patience = patience
    }

    func turn(_ direction: TurnDirection) {
        guard book.currentLocation != nil else { return }
        curl.snapToEnd()
        if let earlier = waitingTurn {
            // It's been overtaken, so it has its move now and no curl.
            waitingTask?.cancel()
            waitingTurn = nil
            _ = move(earlier)
        }
        if moves == 0, startOrDecline(direction) { return }
        waitingTurn = direction
        waitingTask = Task { [weak self] in await self?.waitAndTurn(direction) }
    }

    private func isPastTheEnd(_ direction: TurnDirection) -> Bool {
        guard let here = book.currentLocation else { return true }
        return direction == .forward ? here.isAtEnd : here.isAtStart
    }

    private func image(for direction: TurnDirection) -> CGImage? {
        cache.image(for: direction == .forward ? .next : .previous)
    }

    /// Checks repeatedly because the cache has no event to wait on that can also be given up on.
    private func waitAndTurn(_ direction: TurnDirection) async {
        let deadline = ContinuousClock.now + patience
        while ContinuousClock.now < deadline {
            if moves == 0, isPastTheEnd(direction) || image(for: direction) != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
            if Task.isCancelled { return }
        }
        waitingTurn = nil
        if moves == 0, startOrDecline(direction) { return }
        _ = move(direction)
    }

    /// True if that settles the turn: it's past the end of the book, or its curl has started. Only
    /// call this with no moves running, when the location and images can be trusted.
    private func startOrDecline(_ direction: TurnDirection) -> Bool {
        if isPastTheEnd(direction) { return true }
        guard let target = image(for: direction), let current = cache.image(for: .current) else { return false }
        start(direction, current: current, target: target)
        return true
    }

    private func start(_ direction: TurnDirection, current: CGImage, target: CGImage) {
        let fades = reduceMotion()
        let pieces = TurnImages(direction, current: current, target: target)
        // The move starts after this function, by which time the curl is on its way to the screen.
        let landing = move(direction)
        guard fades || pieces != nil else { return }

        curlNumber += 1
        let number = curlNumber
        let played = { [weak self] in self?.uncover(curl: number, after: landing) ?? () }
        if fades {
            curl.crossfade(from: current, to: target, completion: played)
        } else if let pieces {
            curl.begin(
                direction, front: pieces.front, back: pieces.back,
                beneathLeft: pieces.beneathLeft, beneathRight: pieces.beneathRight)
            curl.play(
                from: direction == .forward ? 0 : 1, to: direction == .forward ? 1 : 0, completion: played)
        }
        // Covers the web view before it can change. WebKit's layer updates arrive on this thread, so
        // they can't overtake this.
        CATransaction.flush()
    }

    /// The web view's move. They reach the book in the order they're made.
    private func move(_ direction: TurnDirection) -> Task<Void, Never> {
        moves += 1
        return Task { [weak self, cache] in
            await cache.commit(direction)
            self?.moves -= 1
        }
    }

    /// Waits for the web view to have the landed page on screen, then uncovers it.
    private func uncover(curl number: Int, after landing: Task<Void, Never>) {
        Task { [weak self] in
            await landing.value
            await self?.pagePainted()
            guard let self, number == self.curlNumber else { return }
            self.curl.end()
        }
    }

    /// A snapshot that waits for screen updates only returns once they've reached this process, and
    /// a one-pixel one costs almost nothing.
    private func pagePainted() async {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        configuration.snapshotWidth = 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            book.webView.takeSnapshot(with: configuration) { _, _ in continuation.resume() }
        }
    }
}
