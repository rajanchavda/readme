import AppKit
import OSLog
import WebKit

enum SpreadSlot {
    case current, next, previous
    /// The spreads one further on, which become `next` and `previous` as soon as a turn lands.
    case afterNext, beforePrevious
}

enum TurnDirection {
    case forward, backward
}

/// Keeps bitmaps of the spreads around the visible one, for the page curl to animate.
///
/// There are two in each direction. A landing promotes the further one at once and the buffer refills
/// behind it, so a reader turning pages quickly always has the next curl ready. An offscreen
/// `BookWebView`, hosted in a window that's never shown because `takeSnapshot` can come back blank
/// without one, renders them. It's kept at the visible view's size, scale, appearance and styles, so
/// a preview is what the reader lands on.
///
/// A slot is nil until its image is ready, and always nil past the ends of the book. Every image
/// belongs to the place last refreshed or committed to, and to that layout. The cache hears the
/// visible view move anywhere else, such as through a link in the book or a `go` call, and renders
/// the slots again around where it went. Call `refresh` after restyling it.
@MainActor
final class SpreadCache {
    /// Called once the cache has heard the visible view go somewhere it didn't take it, and emptied
    /// the slots for the new place.
    var onUnforeseenMove: (() -> Void)?

    private struct Spread {
        var image: CGImage
        var location: ReaderLocation
    }

    /// Everything about the visible view that changes how a spread looks.
    private struct Layout: Equatable {
        var book: URL?
        var size: NSSize
        var scale: CGFloat
        var appearance: NSAppearance.Name
        var css: String
        var columns: Int
        var columnWidth: Double?
        var highlights: [String]
        var highlightColor: String
    }

    /// How many spreads are kept in each direction.
    private static let depth = 2
    /// Longer than the gap between held-key turns, so a burst of them does no offscreen work.
    private static let quietPeriod: Duration = .milliseconds(150)
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "SpreadCache")

    private let visible: BookWebView
    private let offscreen: BookWebView
    private let window: NSWindow

    /// The place the slots belong to.
    private var anchor: ReaderLocation?
    private var layout: Layout?
    private var current: Spread?
    /// Each runs outward from `current`, nearest first, with no gaps.
    private var ahead: [Spread] = []
    private var behind: [Spread] = []
    /// Changes whenever the slots are emptied, so work begun before that can't add to them.
    private var generation = 0
    private var lastDirection = TurnDirection.forward

    /// The rendering in progress. Only one runs at a time, as they share the offscreen view. It reads
    /// the slots as it goes, so it stays useful through turns that were foreseen.
    private var rendering: Task<Void, Never>?
    private var isRendering = false
    private var renderNumber = 0
    private var turnsInFlight = 0
    /// Settles after a turn. What they report is still the turn's doing, even when the page has
    /// paginated a little differently, and `commit` adopts it.
    private var turnsSettling = 0
    private var turnsStarted = 0

    init(visible: BookWebView) {
        self.visible = visible
        let frame = NSRect(origin: .zero, size: visible.bounds.size)
        offscreen = BookWebView(frame: frame)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = offscreen
        visible.addRelocationListener { [weak self] location in self?.visibleMoved(to: location) }
    }

    func image(for slot: SpreadSlot) -> CGImage? {
        switch slot {
        case .current: current?.image
        case .next: ahead.first?.image
        case .previous: behind.first?.image
        case .afterNext: ahead.dropFirst().first?.image
        case .beforePrevious: behind.dropFirst().first?.image
        }
    }

    /// True if `current` shows `location` as the visible view lays it out now, so it and its
    /// neighbours can be shown as the spreads around it.
    func imagesBelong(to location: ReaderLocation) -> Bool {
        current?.location.cfi == location.cfi && visibleLayout() == layout
    }

    /// The memory the images hold, in bytes.
    var bufferedBytes: Int {
        ([current].compactMap { $0 } + ahead + behind).reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height }
    }

    /// Makes the slots right for `location`, where the visible view must be. Only what's missing is
    /// rendered. Returns when the nearest spreads are done, or when a newer refresh or an unforeseen
    /// turn replaces this. The further ones carry on rendering afterwards.
    func refresh(around location: ReaderLocation) async {
        adopt(location)
        await startRendering(after: nil).value
    }

    /// A turn that way is waiting for its images, so the spreads that way are rendered first. A render
    /// going the other way is stopped, unless that way's next spread is already done.
    func prefer(_ direction: TurnDirection) {
        guard lastDirection != direction else { return }
        lastDirection = direction
        let isMissing = (direction == .forward ? ahead : behind).isEmpty
        guard isMissing, isRendering, anchor != nil else { return }
        startRendering(after: nil)
    }

    /// Returns when the work in progress is done, so the slots are as full as they'll get here.
    func neighboursReady() async {
        while let task = rendering {
            await task.value
            if task == rendering { return }
        }
    }

    /// Turns the visible view and moves the images along. `onLanded` is called as soon as the page
    /// has moved and the slots are right for where it went. Returns once the page has settled. Turns
    /// run in the order called.
    func commit(_ direction: TurnDirection, onLanded: (() -> Void)? = nil) async {
        turnsInFlight += 1
        turnsStarted += 1
        lastDirection = direction
        let landed = await direction == .forward ? visible.next() : visible.previous()
        turnsInFlight -= 1
        var foreseen = false
        if let landed {
            foreseen = rotate(direction, landedAt: landed)
            if !foreseen { stopRendering() }
        }
        onLanded?()
        // Held keys skip this: a turn already behind it would make the work pointless.
        guard turnsInFlight == 0 else { return }
        if foreseen && !isRendering { startRendering(after: nil) }

        let turn = turnsStarted
        turnsSettling += 1
        await visible.settle()
        turnsSettling -= 1
        // The view only takes a reply's location if no relocation overtook it, so this is the latest.
        guard turn == turnsStarted, let settled = visible.currentLocation else { return }
        let changed = adopt(settled)
        if current == nil {
            let image = await snapshot(of: visible)
            // A jump while it was taken has adopted its own place, and the image could show either.
            guard turn == turnsStarted, anchor?.cfi == settled.cfi,
                  visible.currentLocation?.cfi == settled.cfi
            else { return }
            if let image { current = Spread(image: image, location: settled) }
        }
        if changed || !isRendering { startRendering(after: foreseen ? nil : Self.quietPeriod) }
    }

    /// An image only moves into `current` if it's known to show where the turn landed, which is what
    /// the CFI comparison is for. A turn that wasn't foreseen, such as one that outran the buffer,
    /// leaves the slots empty for the next render instead. Returns whether it was foreseen.
    private func rotate(_ direction: TurnDirection, landedAt landed: ReaderLocation) -> Bool {
        let leaving = current
        let arriving = (direction == .forward ? ahead : behind).first
        anchor = landed
        guard let arriving, arriving.location.cfi == landed.cfi else {
            empty()
            return false
        }
        current = Spread(image: arriving.image, location: landed)
        var behindIt = direction == .forward ? behind : ahead
        // Without the page it left, what's beyond that wouldn't join on.
        if let leaving {
            behindIt.insert(leaving, at: 0)
            behindIt = Array(behindIt.prefix(Self.depth))
        } else {
            behindIt = []
        }
        let inFront = Array((direction == .forward ? ahead : behind).dropFirst())
        ahead = direction == .forward ? inFront : behindIt
        behind = direction == .forward ? behindIt : inFront
        return true
    }

    /// Every move of the visible view arrives here, including its own turns and their settling,
    /// which `commit` looks after, and the same place reported again, which needs nothing. Until
    /// it's been given a place, the cache has nothing to follow.
    private func visibleMoved(to location: ReaderLocation) {
        guard turnsInFlight == 0, turnsSettling == 0, visible.isBookOpen, let anchor, location.cfi != anchor.cfi else { return }
        adopt(location)
        startRendering(after: nil)
        onUnforeseenMove?()
    }

    private func empty() {
        current = nil
        ahead = []
        behind = []
        generation += 1
    }

    /// Makes `location` and the visible view's layout the ones the slots belong to, emptying the
    /// slots if they were for something else, so a stale image is never on offer. Returns whether
    /// it did.
    @discardableResult
    private func adopt(_ location: ReaderLocation) -> Bool {
        let wanted = visibleLayout()
        let changed = location.cfi != anchor?.cfi || wanted != layout
        if changed { empty() }
        anchor = location
        layout = wanted
        return changed
    }

    private func stopRendering() {
        rendering?.cancel()
        isRendering = false
        renderNumber += 1
    }

    /// The nearest spreads first, in a task of their own for `refresh` to wait on, then the rest.
    @discardableResult
    private func startRendering(after delay: Duration?) -> Task<Void, Never> {
        let earlier = rendering
        stopRendering()
        isRendering = true
        let number = renderNumber
        let task = Task { [weak self] in
            await earlier?.value
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.fill(upTo: 1)
            guard !Task.isCancelled, let self else { return }
            self.rendering = Task { [weak self] in
                await self?.fill(upTo: Self.depth)
                guard let self, number == self.renderNumber else { return }
                self.isRendering = false
            }
        }
        rendering = task
        return task
    }

    private func visibleLayout() -> Layout {
        Layout(
            book: visible.bookURL,
            size: visible.bounds.size,
            scale: visible.window?.backingScaleFactor ?? window.backingScaleFactor,
            appearance: visible.effectiveAppearance.name,
            css: visible.css,
            columns: visible.columns,
            columnWidth: visible.columnWidth,
            highlights: visible.highlightCFIs,
            highlightColor: visible.highlightColor)
    }

    // MARK: Rendering

    /// Renders what's missing until each direction has `depth` spreads, the way the reader is going
    /// first. Reads the slots afresh at each step, and a stopped or outdated render stores nothing, so
    /// a slot can't pick up an image from a place the reader has left.
    private func fill(upTo depth: Int) async {
        var triedCurrent = false
        var prepared = false
        var blocked: [TurnDirection] = []
        while !Task.isCancelled {
            let started = generation
            if current == nil && !triedCurrent && turnsInFlight == 0, let here = anchor {
                triedCurrent = true
                await visible.settle()
                guard !Task.isCancelled, started == generation else { return }
                if visible.currentLocation?.cfi == here.cfi, let image = await snapshot(of: visible) {
                    guard !Task.isCancelled, started == generation else { return }
                    if current == nil, anchor?.cfi == here.cfi { current = Spread(image: image, location: here) }
                }
            }
            guard let direction = wanted(upTo: depth, except: blocked), let layout,
                  let base = frontier(direction)
            else { return }
            if !prepared {
                prepared = true
                guard await prepareOffscreen(for: layout, at: base), started == generation else { return }
            }
            let spread = await neighbour(of: base, going: direction)
            guard !Task.isCancelled, started == generation else { return }
            guard let spread else {
                blocked.append(direction)
                continue
            }
            store(spread, beyond: base, going: direction)
        }
    }

    private func wanted(upTo depth: Int, except blocked: [TurnDirection]) -> TurnDirection? {
        let order: [TurnDirection] = lastDirection == .forward ? [.forward, .backward] : [.backward, .forward]
        return order.first { direction in
            guard !blocked.contains(direction), let edge = frontier(direction) else { return false }
            let count = direction == .forward ? ahead.count : behind.count
            return count < depth && !(direction == .forward ? edge.isAtEnd : edge.isAtStart)
        }
    }

    /// The furthest place known in a direction.
    private func frontier(_ direction: TurnDirection) -> ReaderLocation? {
        (direction == .forward ? ahead : behind).last?.location ?? anchor
    }

    /// Turns can land while a spread renders, and it's still good if it still joins on.
    private func store(_ spread: Spread, beyond base: ReaderLocation, going direction: TurnDirection) {
        guard frontier(direction)?.cfi == base.cfi else { return }
        if direction == .forward {
            if ahead.count < Self.depth { ahead.append(spread) }
        } else {
            if behind.count < Self.depth { behind.append(spread) }
        }
    }

    /// Goes to `location` in the offscreen view, makes the move and photographs where it lands. A
    /// reader going one way leaves the view where this needs it, so there's nothing to go to.
    private func neighbour(of location: ReaderLocation, going direction: TurnDirection) async -> Spread? {
        if offscreen.currentLocation?.cfi != location.cfi {
            _ = await offscreen.go(toCFI: location.cfi)
            guard !Task.isCancelled else { return nil }
        }
        // Starting anywhere else would make a preview of the wrong spread, which is worse than none.
        guard offscreen.currentLocation?.cfi == location.cfi else {
            Self.log.error("The offscreen view could not reach the visible place")
            return nil
        }
        let moved = await direction == .forward ? offscreen.next() : offscreen.previous()
        guard moved != nil, !Task.isCancelled else { return nil }
        await offscreen.settle()
        guard !Task.isCancelled, let landed = offscreen.currentLocation else { return nil }
        guard let image = await snapshot(of: offscreen), !Task.isCancelled else { return nil }
        return Spread(image: image, location: landed)
    }

    private func prepareOffscreen(for layout: Layout, at location: ReaderLocation) async -> Bool {
        guard let book = layout.book else { return false }
        window.appearance = visible.effectiveAppearance
        // Same place, so the same screen and so the same scale, though it's never ordered in.
        let origin = visible.window?.frame.origin ?? window.frame.origin
        window.setFrame(NSRect(origin: origin, size: layout.size), display: false)
        if offscreen.css != layout.css || offscreen.columns != layout.columns
            || offscreen.columnWidth != layout.columnWidth {
            await offscreen.applyStyles(css: layout.css, columns: layout.columns, columnWidth: layout.columnWidth)
            guard !Task.isCancelled else { return false }
        }
        if offscreen.highlightCFIs != layout.highlights || offscreen.highlightColor != layout.highlightColor {
            await offscreen.setHighlights(layout.highlights, color: layout.highlightColor)
            guard !Task.isCancelled else { return false }
        }
        if offscreen.bookURL != book || !offscreen.isBookOpen {
            do {
                _ = try await offscreen.open(book, at: location.cfi)
            } catch {
                Self.log.error("The offscreen view could not open the book: \(String(describing: error), privacy: .public)")
                return false
            }
            guard !Task.isCancelled else { return false }
        }
        await offscreen.settle()
        return !Task.isCancelled
    }

    /// At the backing-store scale: the configuration's default width is in points.
    private func snapshot(of view: BookWebView) async -> CGImage? {
        await withCheckedContinuation { continuation in
            view.webView.takeSnapshot(with: nil) { image, error in
                if let error { Self.log.error("Snapshot failed: \(String(describing: error), privacy: .public)") }
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }
}
