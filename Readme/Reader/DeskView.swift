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

/// Follows a click near the book's outer edges, to tell a plain click there, which turns the page, from
/// one that selects text: a drag, or the first click of a double or triple click.
struct EdgeClick {
    /// How far the pointer may wander between pressing and letting go and still make a click.
    static let slop: CGFloat = 4

    private var pressed: (direction: TurnDirection, point: NSPoint)?

    /// `direction` is which way the page there would turn, if it would. Only a plain first click counts:
    /// a later one is part of a double or triple click, and a modifier means something else, such as
    /// Shift extending a selection.
    mutating func press(at point: NSPoint, direction: TurnDirection?, clickCount: Int, isPlain: Bool) {
        pressed = clickCount == 1 && isPlain ? direction.map { ($0, point) } : nil
    }

    /// Pulling away from where it was pressed makes a selection, not a click.
    mutating func drag(to point: NSPoint) {
        guard let pressed, Self.distance(pressed.point, point) > Self.slop else { return }
        self.pressed = nil
    }

    /// The turn a click asks for once it's let go, if it was a click near an edge.
    mutating func release(at point: NSPoint, clickCount: Int) -> (TurnDirection, NSPoint)? {
        defer { pressed = nil }
        guard let pressed, clickCount == 1, Self.distance(pressed.point, point) <= Self.slop else { return nil }
        return (pressed.direction, pressed.point)
    }

    private static func distance(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The surface the book lies on. A plain click on the outer parts of the book turns the page, once
/// it's clear it isn't the start of a double or triple click. The web view still has every click, so
/// text can be selected anywhere on the page, edges too. Clicks on the bare desk do nothing. It also reads swipes from scrolling, wherever over the window that happens, and
/// hears the mouse move anywhere over it, which wakes the toolbar.
final class DeskView: NSView {
    private static let edgeShare: CGFloat = 0.2

    /// A click on a page's edge, which way it would turn and where it was, in the desk's coordinates.
    var onEdgeClick: ((TurnDirection, NSPoint) -> Void)?
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
    /// page to itself. A plain click near an edge turns the page after the double-click time, unless
    /// another click comes first.
    func follow(_ event: NSEvent, doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval) {
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            pendingTurn?.cancel()
            pendingTurn = nil
            let onChrome = chrome.contains { !$0.isHidden && $0.hitTest(point) != nil }
            let isPlain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
            edgeClick.press(
                at: point, direction: onChrome ? nil : turn(at: point), clickCount: event.clickCount,
                isPlain: isPlain)
        case .leftMouseDragged:
            edgeClick.drag(to: point)
        case .leftMouseUp:
            guard let (direction, at) = edgeClick.release(at: point, clickCount: event.clickCount) else { return }
            let turn = DispatchWorkItem { [weak self] in
                self?.pendingTurn = nil
                self?.onEdgeClick?(direction, at)
            }
            pendingTurn = turn
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval, execute: turn)
        default:
            break
        }
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
