import AppKit
import OSLog
import WebKit

enum SpreadSlot {
    case current, next, previous
}

enum TurnDirection {
    case forward, backward
}

/// Keeps bitmaps of the spreads either side of the visible one, for the page curl to animate.
///
/// An offscreen `BookWebView`, hosted in a window that's never shown because `takeSnapshot` can come
/// back blank without one, renders the neighbours. It's kept at the visible view's size, scale,
/// appearance and styles, so a preview is what the reader lands on.
///
/// A slot is nil until its image is ready, and always nil past the ends of the book. Every image
/// belongs to the place last refreshed or committed to, and to that layout. Call `refresh` after
/// anything else moves or restyles the visible view.
@MainActor
final class SpreadCache {
    private struct Spread {
        var image: CGImage
        var cfi: String
    }

    /// Everything about the visible view that changes how a spread looks.
    private struct Layout: Equatable {
        var book: URL?
        var size: NSSize
        var scale: CGFloat
        var appearance: NSAppearance.Name
        var css: String
        var columns: Int
    }

    /// Longer than the gap between held-key turns, so a burst of them does no offscreen work.
    private static let quietPeriod: Duration = .milliseconds(150)
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "SpreadCache")

    private let visible: BookWebView
    private let offscreen: BookWebView
    private let window: NSWindow

    /// The place the slots belong to.
    private var anchor: String?
    private var layout: Layout?
    private var current: Spread?
    private var next: Spread?
    private var previous: Spread?

    /// The rendering in progress. Only one runs at a time, as they share the offscreen view.
    private var rendering: Task<Void, Never>?
    private var turnsInFlight = 0
    private var turnsStarted = 0

    init(visible: BookWebView) {
        self.visible = visible
        let frame = NSRect(origin: .zero, size: visible.bounds.size)
        offscreen = BookWebView(frame: frame)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = offscreen
    }

    func image(for slot: SpreadSlot) -> CGImage? {
        switch slot {
        case .current: current?.image
        case .next: next?.image
        case .previous: previous?.image
        }
    }

    /// Makes the slots right for `location`, where the visible view must be. Only what's missing is
    /// rendered. Returns when that's done, or when a newer refresh or a turn replaces this one.
    func refresh(around location: ReaderLocation) async {
        await startRendering(around: location, layout: adopt(location), after: nil).value
    }

    /// Returns when the work in progress is done, so the slots are as full as they'll get here.
    func neighboursReady() async {
        while let task = rendering {
            await task.value
            if task == rendering { return }
        }
    }

    /// Turns the visible view and moves the images along. Returns once the page has landed. The new
    /// neighbour renders afterwards, without holding up further turns. Turns run in the order called.
    func commit(_ direction: TurnDirection) async {
        turnsInFlight += 1
        turnsStarted += 1
        rendering?.cancel()
        let landed = await direction == .forward ? visible.next() : visible.previous()
        turnsInFlight -= 1
        // Also stops a refresh that began while the turn was under way, for the place it left.
        rendering?.cancel()
        if let landed { rotate(direction, landedAt: landed) }
        guard turnsInFlight == 0 else { return }

        // Held keys skip this: a turn already behind it would make the work pointless.
        let turn = turnsStarted
        await visible.settle()
        guard turn == turnsStarted, let settled = visible.currentLocation else { return }
        let wanted = adopt(settled)
        if current == nil {
            let image = await snapshot(of: visible)
            guard turn == turnsStarted else { return }
            if let image { current = Spread(image: image, cfi: settled.cfi) }
        }
        startRendering(around: settled, layout: wanted, after: Self.quietPeriod)
    }

    /// An image only moves into `current` if it's known to show where the turn landed. A turn that
    /// wasn't foreseen, such as one in a burst, leaves the slots empty for the next render instead.
    private func rotate(_ direction: TurnDirection, landedAt landed: ReaderLocation) {
        let leaving = current
        let arriving = direction == .forward ? next : previous
        let foreseen = arriving?.cfi == landed.cfi
        anchor = landed.cfi
        current = foreseen ? arriving : nil
        next = foreseen && direction == .backward ? leaving : nil
        previous = foreseen && direction == .forward ? leaving : nil
    }

    /// Makes `location` and the visible view's layout the ones the slots belong to, emptying any
    /// slot that was for something else, so a stale image is never on offer.
    private func adopt(_ location: ReaderLocation) -> Layout {
        let wanted = visibleLayout()
        if location.cfi != anchor || wanted != layout {
            current = nil
            next = nil
            previous = nil
        }
        anchor = location.cfi
        layout = wanted
        return wanted
    }

    @discardableResult
    private func startRendering(
        around location: ReaderLocation, layout wanted: Layout, after delay: Duration?
    ) -> Task<Void, Never> {
        let earlier = rendering
        earlier?.cancel()
        let task = Task { [weak self] in
            await earlier?.value
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.render(around: location, layout: wanted)
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
            columns: visible.columns)
    }

    // MARK: Rendering

    /// Stops at the next step when cancelled, and a cancelled render stores nothing, so a slot can't
    /// pick up an image from a place the reader has left.
    private func render(around location: ReaderLocation, layout: Layout) async {
        if current == nil {
            await visible.settle()
            guard !Task.isCancelled else { return }
            if visible.currentLocation?.cfi == location.cfi, let image = await snapshot(of: visible) {
                guard !Task.isCancelled else { return }
                current = Spread(image: image, cfi: location.cfi)
            }
        }
        guard next == nil && !location.isAtEnd || previous == nil && !location.isAtStart,
              await prepareOffscreen(for: layout, at: location)
        else { return }

        if next == nil && !location.isAtEnd {
            let spread = await neighbour(of: location, move: { await $0.next() })
            guard !Task.isCancelled else { return }
            next = spread
        }
        if previous == nil && !location.isAtStart {
            let spread = await neighbour(of: location, move: { await $0.previous() })
            guard !Task.isCancelled else { return }
            previous = spread
        }
    }

    /// Goes to `location` in the offscreen view, makes the move and photographs where it lands.
    private func neighbour(
        of location: ReaderLocation, move: (BookWebView) async -> ReaderLocation?
    ) async -> Spread? {
        if offscreen.currentLocation?.cfi != location.cfi {
            _ = await offscreen.go(toCFI: location.cfi)
            guard !Task.isCancelled else { return nil }
        }
        // Starting anywhere else would make a preview of the wrong spread, which is worse than none.
        guard offscreen.currentLocation?.cfi == location.cfi else {
            Self.log.error("The offscreen view could not reach the visible place")
            return nil
        }
        guard await move(offscreen) != nil, !Task.isCancelled else { return nil }
        await offscreen.settle()
        guard !Task.isCancelled, let cfi = offscreen.currentLocation?.cfi else { return nil }
        guard let image = await snapshot(of: offscreen), !Task.isCancelled else { return nil }
        return Spread(image: image, cfi: cfi)
    }

    private func prepareOffscreen(for layout: Layout, at location: ReaderLocation) async -> Bool {
        guard let book = layout.book else { return false }
        window.appearance = visible.effectiveAppearance
        // Same place, so the same screen and so the same scale, though it's never ordered in.
        let origin = visible.window?.frame.origin ?? window.frame.origin
        window.setFrame(NSRect(origin: origin, size: layout.size), display: false)
        if offscreen.css != layout.css || offscreen.columns != layout.columns {
            await offscreen.applyStyles(css: layout.css, columns: layout.columns)
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
