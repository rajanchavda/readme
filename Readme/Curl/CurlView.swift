import AppKit
import QuartzCore

/// Draws a page turning over bitmaps of the book, covering the web view while it does.
///
/// The turning page is a chain of `CurlPose.strips` strips hinged at their left edges, each with a
/// front and a back face showing its slice of a bitmap, as in `docs/mockups/open-book-v2.html`. The
/// view covers the book exactly and lets the page overflow it, so it should sit where that can show.
///
/// A finished `play` leaves the turned page lying flat, which keeps showing the landed spread with no
/// strips until `end` removes it, so the host can wait for the page underneath to be ready.
@MainActor
final class CurlView: NSView {
    private struct Strip {
        let layer: CATransformLayer
        let front: CALayer
        let back: CALayer
        let frontShade: CAGradientLayer
        let backShade: CAGradientLayer
    }

    /// A timed change, driven by the display link.
    private struct Animation {
        let duration: Double
        let step: (Double) -> Void
        let finish: () -> Void
        let completion: () -> Void
        var startTime: CFTimeInterval?
    }

    private static let perspective: CGFloat = 2400
    private static let crossfadeDuration = 0.2
    private static let flatteningShare = 0.05
    /// Display links don't tick for a window that's hidden or covered, but a turn must still end.
    private static let safetyMargin: Duration = .milliseconds(250)

    private(set) var progress = 0.0
    private(set) var direction = TurnDirection.forward

    private var strips: [Strip] = []
    private var pageLeft: CALayer?
    private var pageRight: CALayer?
    private var cast: CAGradientLayer?
    private var frontImage: CGImage?
    private var backImage: CGImage?
    private var crossfadeTop: CALayer?

    private var animation: Animation?
    private var link: CADisplayLink?
    private var safetyTimer: Task<Void, Never>?
    /// The frame the pose being made is for, when the display link is making it.
    private var poseTarget: Double?

    /// Measures each turn from `begin` until the page lies flat or the curl comes off.
    let frameMonitor = CurlFrameMonitor()

    var isPlaying: Bool { animation != nil }
    var isCrossfading: Bool { crossfadeTop != nil }
    var isShowing: Bool { !isHidden }

    // MARK: Exposed for tests

    var stripLayers: [CALayer] { strips.map(\.layer) }
    var stripFaces: [(front: CALayer, back: CALayer)] { strips.map { ($0.front, $0.back) } }
    var beneathLayers: (left: CALayer?, right: CALayer?) { (pageLeft, pageRight) }
    var castLayer: CALayer? { cast }

    // MARK: Setting up

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CurlView is created in code")
    }

    /// Clicks and keys belong to whatever's underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the turn at its start: progress 0 going forward and 1 going backward, because a backward
    /// turn is a forward one played in reverse. Each image is one page, not a spread.
    func begin(
        _ d: TurnDirection, front: CGImage, back: CGImage, beneathLeft: CGImage, beneathRight: CGImage
    ) {
        let setUpTime = CACurrentMediaTime()
        clear()
        direction = d
        frontImage = front
        backImage = back
        withoutActions {
            let pageWidth = bounds.width / 2
            let page = CGRect(x: 0, y: 0, width: pageWidth, height: bounds.height)
            pageLeft = addImageLayer(beneathLeft, frame: page)
            pageRight = addImageLayer(beneathRight, frame: page.offsetBy(dx: pageWidth, dy: 0))
            cast = addCast()
            buildStrips(front: front, back: back, pageWidth: pageWidth)
            isHidden = false
        }
        setProgress(d == .forward ? 0 : 1)
        frameMonitor.start(on: self, direction: d, setUpTime: setUpTime)
    }

    /// Fades one whole spread into another, for readers who've asked for less motion.
    func crossfade(from: CGImage, to: CGImage, completion: @escaping () -> Void) {
        clear()
        withoutActions {
            pageLeft = addImageLayer(to, frame: bounds)
            crossfadeTop = addImageLayer(from, frame: bounds)
            isHidden = false
        }
        run(
            duration: Self.crossfadeDuration,
            step: { [weak self] p in
                self?.withoutActions { self?.crossfadeTop?.opacity = Float((1 - p) * (1 - p)) }
            },
            finish: { [weak self] in
                self?.withoutActions {
                    self?.crossfadeTop?.removeFromSuperlayer()
                    self?.crossfadeTop = nil
                }
            },
            completion: completion)
    }

    private func addImageLayer(_ image: CGImage, frame: CGRect) -> CALayer {
        let picture = CALayer()
        picture.frame = frame
        picture.contents = image
        picture.contentsScale = Self.scale(of: image, width: frame.width)
        layer?.addSublayer(picture)
        return picture
    }

    /// The soft shadow the turning page throws across the spread beneath it.
    private func addCast() -> CAGradientLayer {
        let shadow = CAGradientLayer()
        shadow.frame = bounds
        shadow.startPoint = CGPoint(x: 0, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 0.5)
        shadow.colors = [
            CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.2), CGColor(gray: 0, alpha: 0),
        ]
        shadow.locations = [0.18, 0.5, 0.82]
        shadow.opacity = 0
        layer?.addSublayer(shadow)
        return shadow
    }

    private func buildStrips(front: CGImage, back: CGImage, pageWidth: CGFloat) {
        // Applied about its centre, the spine, like the mockup's perspective on the book.
        let stage = CALayer()
        stage.frame = bounds
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / Self.perspective
        stage.sublayerTransform = perspective
        layer?.addSublayer(stage)

        let count = CurlPose.strips
        let stripWidth = pageWidth / CGFloat(count)
        let height = bounds.height
        var parent = stage
        strips = (0..<count).map { index in
            let chain = CATransformLayer()
            chain.bounds = CGRect(x: 0, y: 0, width: stripWidth, height: height)
            chain.anchorPoint = CGPoint(x: 0, y: 0.5)
            chain.position = CGPoint(x: index == 0 ? pageWidth : stripWidth, y: height / 2)
            parent.addSublayer(chain)
            parent = chain

            let isLast = index == count - 1
            let faceFrame = chain.bounds
            let slice = stripWidth / pageWidth

            let frontFace = makeFace(front, frame: faceFrame, outerEdge: isLast ? .layerRightEdge : [])
            frontFace.contentsRect = CGRect(x: CGFloat(index) * slice, y: 0, width: slice, height: 1)
            chain.addSublayer(frontFace)

            // Facing the other way, so its slice runs from the spine outward along the chain.
            let backFace = makeFace(back, frame: faceFrame, outerEdge: isLast ? .layerLeftEdge : [])
            backFace.transform = CATransform3DMakeRotation(.pi, 0, 1, 0)
            backFace.contentsRect = CGRect(x: 1 - CGFloat(index + 1) * slice, y: 0, width: slice, height: 1)
            chain.addSublayer(backFace)

            return Strip(
                layer: chain, front: frontFace, back: backFace,
                frontShade: addShade(to: frontFace, spineOnLeft: true),
                backShade: addShade(to: backFace, spineOnLeft: false))
        }
    }

    /// Faces share the bitmap, so it's uploaded once. Only the page's outside edges are smoothed.
    /// A smoothed hinge leaves a line: both neighbours partly cover the pixels there, letting a little
    /// of what's behind them through. Overlapping the strips instead, as the mockup does, shades those
    /// pixels twice or not at all, because Core Animation depth-sorts each face and shade separately.
    private func makeFace(_ image: CGImage, frame: CGRect, outerEdge: CAEdgeAntialiasingMask) -> CALayer {
        let face = CALayer()
        face.frame = frame
        face.contents = image
        face.contentsScale = Self.scale(of: image, width: bounds.width / 2)
        face.isDoubleSided = false
        face.allowsEdgeAntialiasing = true
        face.edgeAntialiasingMask = outerEdge.union([.layerTopEdge, .layerBottomEdge])
        return face
    }

    /// Starts at the spine side, so a shade can be set the same way on either face. Its edges match
    /// its face's, so the two cover exactly the same pixels.
    private func addShade(to face: CALayer, spineOnLeft: Bool) -> CAGradientLayer {
        let shade = CAGradientLayer()
        shade.frame = face.bounds
        shade.startPoint = CGPoint(x: spineOnLeft ? 0 : 1, y: 0.5)
        shade.endPoint = CGPoint(x: spineOnLeft ? 1 : 0, y: 0.5)
        shade.isDoubleSided = false
        shade.allowsEdgeAntialiasing = true
        shade.edgeAntialiasingMask = face.edgeAntialiasingMask
        face.addSublayer(shade)
        return shade
    }

    /// Pixels per point of a bitmap drawn at `width` points, so it's shown at its full resolution.
    private static func scale(of image: CGImage, width: CGFloat) -> CGFloat {
        width > 0 ? CGFloat(image.width) / width : 1
    }

    // MARK: Moving

    func setProgress(_ t: Double) {
        guard let cast else { return }
        let started = CACurrentMediaTime()
        progress = t
        withoutActions {
            let angles = Self.drawnAngles(t: t)
            var previous = 0.0
            for (index, strip) in strips.enumerated() {
                let angle = angles[index]
                strip.layer.transform = CATransform3DMakeRotation((angle - previous) * .pi / 180, 0, 1, 0)
                // Darkness is that of the hinge at each end, where neighbouring strips agree. One
                // flat shade per strip would show the strips as bands on a pale page.
                let outer = angles[min(index + 1, angles.count - 1)]
                let colors = [
                    CGColor(gray: 0, alpha: CurlPose.shade(angle: (angle + (index == 0 ? angle : previous)) / 2)),
                    CGColor(gray: 0, alpha: CurlPose.shade(angle: (angle + outer) / 2)),
                ]
                strip.frontShade.colors = colors
                strip.backShade.colors = colors
                previous = angle
            }
            cast.opacity = Float(CurlPose.cast(t: t))
        }
        frameMonitor.posed(started: started, target: poseTarget)
    }

    /// `CurlPose.angles`, except that `CurlPose` stops 0.5 degrees short of flat, which would make the
    /// page jump as a backward turn begins and a forward one ends. This closes the gap over the last
    /// `flatteningShare` of the turn.
    static func drawnAngles(t: Double) -> [Double] {
        let closing = min(1, max(0, (t - (1 - flatteningShare)) / flatteningShare)) * 0.5
        return CurlPose.angles(t: t).map { max(-180, $0 - closing) }
    }

    /// Runs from one progress to another at the curl's pace, then lays the page flat where it fell.
    func play(from: Double, to: Double, completion: @escaping () -> Void) {
        setProgress(from)
        run(
            duration: abs(to - from) * CurlPose.duration,
            step: { [weak self] p in self?.setProgress(from + (to - from) * p) },
            finish: { [weak self] in self?.layFlat(at: to) },
            completion: completion)
    }

    /// Replaces the strips with the page they became, flat like the web view's page, not 0.5 degrees
    /// off it, so there's no jump when the web view takes over.
    private func layFlat(at t: Double) {
        frameMonitor.stop()
        withoutActions {
            if t >= 1 { pageLeft?.contents = backImage } else { pageRight?.contents = frontImage }
            cast?.opacity = 0
            strips.first?.layer.superlayer?.removeFromSuperlayer()
            strips = []
        }
    }

    /// Finishes whatever's playing at once, completion included.
    func snapToEnd() {
        finishAnimation()
    }

    /// Removes the curl, showing what's underneath. Any animation is dropped, unfinished.
    func end() {
        clear()
        withoutActions { isHidden = true }
    }

    private func clear() {
        frameMonitor.stop()
        stopAnimation()
        withoutActions {
            layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        strips = []
        pageLeft = nil
        pageRight = nil
        cast = nil
        crossfadeTop = nil
        frontImage = nil
        backImage = nil
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    // MARK: Timing

    private func run(
        duration: Double, step: @escaping (Double) -> Void, finish: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        stopAnimation()
        animation = Animation(duration: duration, step: step, finish: finish, completion: completion)
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        safetyTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration) + Self.safetyMargin)
            if !Task.isCancelled { self?.finishAnimation() }
        }
    }

    /// Timed from the first frame shown, as in the mockup, so a slow start doesn't lose any of the
    /// curl. Each frame is posed for the moment it reaches the screen.
    @objc private func tick(_ link: CADisplayLink) {
        guard let current = animation else { return }
        poseTarget = link.targetTimestamp
        defer { poseTarget = nil }
        guard let start = current.startTime else {
            animation?.startTime = link.targetTimestamp
            current.step(0)
            return
        }
        let elapsed = link.targetTimestamp - start
        if elapsed >= current.duration {
            finishAnimation()
        } else {
            current.step(elapsed / current.duration)
        }
    }

    private func finishAnimation() {
        guard let finished = animation else { return }
        stopAnimation()
        finished.finish()
        finished.completion()
    }

    private func stopAnimation() {
        animation = nil
        link?.invalidate()
        link = nil
        safetyTimer?.cancel()
        safetyTimer = nil
    }
}
