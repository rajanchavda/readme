import AppKit
import QuartzCore

/// The soft shadow where the two pages meet. It belongs to the pages, as the mockup's inset shadow
/// on each page does, so a turning page passes over it: the window draws it on the book, and the
/// curl on the pages beneath the turning one.
enum SpineShadow {
    /// How far the shadow reaches into each page. The mockup's `inset 26px 0 26px -20px` shadow is
    /// a hard edge 6 points in, blurred over 26.
    static let reach: CGFloat = 32
    /// Its darkness, as a share of the colour's, 32, 20, 12, 6 and 0 points from the spine.
    private static let falloff: [(location: Double, share: CGFloat)] = [
        (0, 0), (0.375, 0.14), (0.625, 0.32), (0.8125, 0.5), (1, 0.68),
    ]

    /// One gradient for each page, darkest at the spine.
    static func makeLayers() -> (left: CAGradientLayer, right: CAGradientLayer) {
        let left = CAGradientLayer(), right = CAGradientLayer()
        for (shadow, towardsSpine) in [(left, true), (right, false)] {
            shadow.startPoint = CGPoint(x: towardsSpine ? 0 : 1, y: 0.5)
            shadow.endPoint = CGPoint(x: towardsSpine ? 1 : 0, y: 0.5)
            shadow.locations = falloff.map { NSNumber(value: $0.location) }
        }
        return (left, right)
    }

    /// Frames for a book `bounds` wide, meeting at its middle.
    static func frames(in bounds: CGRect) -> (left: CGRect, right: CGRect) {
        let middle = bounds.width / 2
        return (CGRect(x: middle - reach, y: 0, width: reach, height: bounds.height),
                CGRect(x: middle, y: 0, width: reach, height: bounds.height))
    }

    static func colors(_ color: CGColor) -> [CGColor] {
        falloff.map { color.copy(alpha: color.alpha * $0.share) ?? color }
    }
}

/// The spine's shadow on the book.
final class SpineView: NSView {
    private let left: CAGradientLayer
    private let right: CAGradientLayer

    override init(frame: NSRect) {
        (left, right) = SpineShadow.makeLayers()
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(left)
        layer?.addSublayer(right)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpineView is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (left.frame, right.frame) = SpineShadow.frames(in: bounds)
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    func setColor(_ color: CGColor, animated: Bool) {
        let colors = SpineShadow.colors(color)
        for shadow in [left, right] {
            if animated {
                let animation = CABasicAnimation(keyPath: "colors")
                animation.fromValue = shadow.presentation()?.colors ?? shadow.colors
                animation.toValue = colors
                animation.duration = 0.2
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shadow.add(animation, forKey: "colors")
            }
            shadow.colors = colors
        }
    }
}
