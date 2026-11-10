import AppKit

/// The reading marker on the page: a narrow bookmark ribbon hanging from the top edge of the right-hand
/// page, with a V cut into its tail. It lies on the book, under the curl, so a turning page passes over
/// it, and the window hides it while pages turn so it never rides onto the wrong one.
final class MarkerRibbon: NSView {
    static let size = NSSize(width: 14, height: 36)
    /// How far in from the page's outer edge it hangs.
    static let inset: CGFloat = 34
    /// How deep the V in its tail is.
    private static let notch: CGFloat = 6

    var color: NSColor = .systemRed {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Reading marker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MarkerRibbon is created in code")
    }

    override var isFlipped: Bool { false }

    /// Clicks go through to the page beneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let path = NSBezierPath()
        path.move(to: NSPoint(x: b.minX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.maxY))
        path.line(to: NSPoint(x: b.maxX, y: b.minY))
        path.line(to: NSPoint(x: b.midX, y: b.minY + Self.notch))
        path.line(to: NSPoint(x: b.minX, y: b.minY))
        path.close()
        color.setFill()
        path.fill()
        // A faint shade down one side, so it reads as a ribbon lying on the paper rather than a flat shape.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSRect(x: b.maxX - 3, y: b.minY, width: 3, height: b.height).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Where it hangs on a book laid out in `bookFrame`: from the top of the right-hand page, or of the
    /// one page when there's only one, `inset` in from its outer edge.
    static func frame(in bookFrame: CGRect) -> CGRect {
        CGRect(
            x: (bookFrame.maxX - inset - size.width).rounded(),
            y: (bookFrame.maxY - size.height).rounded(),
            width: size.width, height: size.height)
    }
}
