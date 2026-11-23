import AppKit

/// What the reading window does with a scroll event. Under a sheet it's swallowed, as handing it back
/// would let normal dispatch bring it to the desk anyway. The open contents scroll their own list, and
/// pages don't turn beside them.
enum ScrollRoute: Equatable {
    case passOn, swallow, desk

    /// Where the contents sidebar is, if it's open, relative to the pointer.
    enum Contents {
        case closed, under, beside
    }

    init(isOurWindow: Bool, hasSheet: Bool, contents: Contents = .closed) {
        if !isOurWindow {
            self = .passOn
        } else if hasSheet {
            self = .swallow
        } else {
            switch contents {
            case .closed: self = .desk
            case .under: self = .passOn
            case .beside: self = .swallow
            }
        }
    }
}

/// What's under a click near the book's outer edges, which says whether it turns the page.
enum EdgeSpot: String {
    /// A link, which the page follows, or a highlight, which it shows. The page has the click, as it
    /// has any click while text is selected, which only puts the selection away.
    case own
    /// Text, which a double or triple click would select.
    case text
    /// Nothing to select, such as a margin or the gap between lines.
    case blank
}

/// What a click near an edge does with the page.
enum EdgeTurn: Equatable {
    case none
    case now
    /// Once the double-click time has passed with no other press, in case it's the start of one.
    case afterDoubleClick
}

/// Follows a click near the book's outer edges, to tell a plain click there, which turns the page, from
/// one that selects text: a drag, or a double or triple click on text.
struct EdgeClick {
    /// How far the pointer may wander between pressing and letting go and still make a click.
    static let slop: CGFloat = 4

    struct Click: Equatable {
        var direction: TurnDirection
        var point: NSPoint
        var clickCount: Int
    }

    private var pressed: Click?

    /// Whether a press is being followed as a possible turn.
    var isPressed: Bool { pressed != nil }

    /// Over text, a single click waits to see it isn't a double one, and a double or triple click
    /// selects. Elsewhere every click of a run turns, so quick clicks flip quickly, and once a run has
    /// turned the page its later clicks are more turns, wherever they land on the new page.
    static func turn(for spot: EdgeSpot, clickCount: Int, runHasTurned: Bool = false) -> EdgeTurn {
        switch spot {
        case .own: .none
        case .blank: .now
        case .text where clickCount > 1 && runHasTurned: .now
        case .text: clickCount == 1 ? .afterDoubleClick : .none
        }
    }

    /// `direction` is which way the page there would turn, if it would. A modifier means something
    /// other than a turn, such as Shift extending a selection.
    mutating func press(at point: NSPoint, direction: TurnDirection?, clickCount: Int, isPlain: Bool) {
        pressed = isPlain ? direction.map { Click(direction: $0, point: point, clickCount: clickCount) } : nil
    }

    /// Pulling away from where it was pressed makes a selection, not a click.
    mutating func drag(to point: NSPoint) {
        guard let pressed, Self.distance(pressed.point, point) > Self.slop else { return }
        self.pressed = nil
    }

    /// The click near an edge that's just been let go, if it was one.
    mutating func release(at point: NSPoint) -> Click? {
        defer { pressed = nil }
        guard let pressed, Self.distance(pressed.point, point) <= Self.slop else { return nil }
        return pressed
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The surface the book lies on. A plain click on the outer parts of the book turns the page (see
/// `EdgeClick`). The web view still has every click, so text can be selected anywhere on the page,
/// edges too. Clicks on the bare desk do nothing. It also reads swipes from scrolling, wherever over
/// the window that happens, and hears the mouse move anywhere over it, which wakes the toolbar.
final class DeskView: NSView {
    private static let edgeShare: CGFloat = 0.2

    /// A click on a page's edge that turns the page, and which way.
    var onEdgeClick: ((TurnDirection) -> Void)?
    /// Asks what's under a point near an edge, in the desk's coordinates. The question must be on its
    /// way before this returns, as the click reaches the page right after. Without it, nothing is.
    var spotAt: ((NSPoint) -> Task<EdgeSpot, Never>)?
    var onSwipe: ((SwipeSignal) -> Void)?
    /// Where the mouse is, in the desk's coordinates.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var bookFrame: NSRect
    /// Controls laid over the book, such as the toolbar, which take a click before the page's edge does.
    var chrome: [NSView] = []
    private var gesture = SwipeGesture()
    private var edgeClick = EdgeClick()
    private var pendingTurn: DispatchWorkItem?
    /// What's under the press being followed, asked as the button went down.
    private var pressedSpot: Task<EdgeSpot, Never>?
    /// Counts presses on the page, so a click's turn still being decided knows another press came, and
    /// waits for no double-click time.
    private var presses = 0
    /// Counts `cancelEdgeTurn`, so no click's turn still being decided outlives the reader moving on.
    private var cancels = 0
    /// Whether a click of the run under way has turned the page, which makes its later clicks turns.
    private var runHasTurned = false
    /// Whether the latest press on the page is still a click near an edge, not a drag or a click
    /// elsewhere, so a turn answered late doesn't land in the middle of something else.
    private var isOnEdge = false

    init(frame: NSRect, bookFrame: NSRect) {
        self.bookFrame = bookFrame
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(srgbRed: 0x3A / 255, green: 0x33 / 255, blue: 0x2C / 255, alpha: 1)
        // Over the web view too, which is why it's a tracking area and not the view's own events.
        // Always active, so the title bar's buttons show over a window that isn't the key one.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DeskView is created in code")
    }

    /// Which way a click at `point` turns the page, if it does.
    func turn(at point: NSPoint) -> TurnDirection? {
        guard bookFrame.contains(point) else { return nil }
        let band = bookFrame.width * Self.edgeShare
        if point.x < bookFrame.minX + band { return .backward }
        if point.x > bookFrame.maxX - band { return .forward }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in chrome where !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return super.hitTest(point)
    }

    /// Hears the left button over the window, wherever it went, as the web view keeps clicks on the
    /// page to itself. A plain click near an edge turns the page, at once or after the double-click
    /// time, by what's under it.
    func follow(_ event: NSEvent, doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval) {
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            // A press on the toolbar is no part of a run of clicks on the page. What its button does
            // may still drop a turn that's waiting (see `cancelEdgeTurn`).
            if chrome.contains(where: { !$0.isHidden && $0.hitTest(point) != nil }) {
                edgeClick.press(at: point, direction: nil, clickCount: event.clickCount, isPlain: true)
                pressedSpot = nil
                return
            }
            presses += 1
            pendingTurn?.cancel()
            pendingTurn = nil
            let isPlain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            edgeClick.press(at: point, direction: turn(at: point), clickCount: event.clickCount, isPlain: isPlain)
            isOnEdge = edgeClick.isPressed
            if event.clickCount <= 1 || !isOnEdge { runHasTurned = false }
            // Asked now, before the page sees the click and maybe follows a link to another page.
            pressedSpot = edgeClick.isPressed ? spotAt?(point) ?? Task { .blank } : nil
        case .leftMouseDragged:
            edgeClick.drag(to: point)
            isOnEdge = isOnEdge && edgeClick.isPressed
        case .leftMouseUp:
            guard let click = edgeClick.release(at: point), let spot = pressedSpot else {
                isOnEdge = false
                return
            }
            pressedSpot = nil
            // The double-click time runs from letting go, however long the page takes to answer.
            let deadline = DispatchTime.now() + doubleClickInterval
            let (presses, cancels) = (presses, cancels)
            Task { [weak self] in
                let found = await spot.value
                guard let self, self.cancels == cancels else { return }
                switch EdgeClick.turn(for: found, clickCount: click.clickCount, runHasTurned: self.runHasTurned) {
                case .none:
                    break
                case .now:
                    // Every click of a quick run turns, even one answered after the next press, as long
                    // as that press is another click near an edge.
                    guard self.presses == presses || self.isOnEdge else { return }
                    self.runHasTurned = true
                    self.onEdgeClick?(click.direction)
                case .afterDoubleClick:
                    guard self.presses == presses else { return }
                    let turn = DispatchWorkItem { [weak self] in
                        self?.pendingTurn = nil
                        self?.onEdgeClick?(click.direction)
                    }
                    self.pendingTurn = turn
                    DispatchQueue.main.asyncAfter(deadline: deadline, execute: turn)
                }
            }
        default:
            break
        }
    }

    /// Drops an edge click's turn that hasn't happened yet, as when the reader's moved on from the page.
    func cancelEdgeTurn() {
        cancels += 1
        pendingTurn?.cancel()
        pendingTurn = nil
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    /// Only a trackpad-style gesture has a phase, so a mouse wheel does nothing, and momentum has none
    /// of its own: it comes after the fingers have gone, with the page no longer theirs.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, let phase = Self.gesturePhase(of: event) else { return }
        let travel = SwipeGesture.fingerTravel(
            scrollingDeltaX: event.scrollingDeltaX, isDirectionInverted: event.isDirectionInvertedFromDevice)
        send(gesture.handle(phase, deltaX: travel, deltaY: event.scrollingDeltaY, at: event.timestamp))
    }

    func abandonSwipe() {
        send(gesture.abandon())
    }

    private func send(_ signals: [SwipeSignal]) {
        signals.forEach { onSwipe?($0) }
    }

    private static func gesturePhase(of event: NSEvent) -> SwipeGesture.Phase? {
        switch event.phase {
        case .began: .began
        case .changed, .stationary: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        default: nil
        }
    }
}
