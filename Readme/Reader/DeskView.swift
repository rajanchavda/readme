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

/// The surface the book lies on. It takes clicks on the outer parts of the book, which turn pages,
/// and leaves the rest of the book to the web view, so text can still be selected. Clicks on the bare
/// desk do nothing. It also reads swipes from scrolling, wherever over the window that happens, and
/// hears the mouse move anywhere over it, which wakes the toolbar.
final class DeskView: NSView {
    private static let edgeShare: CGFloat = 0.2

    var onEdgeClick: ((TurnDirection) -> Void)?
    var onSwipe: ((SwipeSignal) -> Void)?
    /// Where the mouse is, in the desk's coordinates.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var bookFrame: NSRect
    /// Controls laid over the book, such as the toolbar, which take a click before the page's edge does.
    var chrome: [NSView] = []
    private var gesture = SwipeGesture()

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
        return turn(at: local) != nil ? self : super.hitTest(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let direction = turn(at: convert(event.locationInWindow, from: nil)) else { return }
        onEdgeClick?(direction)
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
