import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// A bitmap with a colour per side, to tell which half went where.
private func spread(width: Int = 2000, height: Int = 1400, left: CGColor, right: CGColor) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(left)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(right)
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return try #require(context.makeImage())
}

private let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
private let green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
private let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
private let yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)

/// The colour of a bitmap's only colour, as 8-bit red, green and blue.
private func colour(of image: CGImage) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Array(pixel[0..<3])
}

private func relativeRotation(of layer: CALayer) -> Double {
    // A rotation about y: m11 is its cosine and m13 minus its sine.
    let transform = layer.transform
    return atan2(-Double(transform.m13), Double(transform.m11)) * 180 / .pi
}

/// The book tests use a window that's never shown, as in `SpreadCacheTests`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct CurlViewTests {
    let window: NSWindow
    let view: BookWebView
    let cache: SpreadCache
    let curl: CurlView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: frame)
        view = BookWebView(frame: frame)
        curl = CurlView(frame: frame)
        content.addSubview(view)
        content.addSubview(curl)
        window.contentView = content
        cache = SpreadCache(visible: view)
    }

    private func preparedCurl() throws -> CurlView {
        let half = try spread(width: 1000, left: red, right: red)
        curl.begin(.forward, front: half, back: half, beneathLeft: half, beneathRight: half)
        return curl
    }

    private func coordinator(
        reduceMotion: Bool = false, patience: Duration = TurnCoordinator.defaultPatience
    ) -> TurnCoordinator {
        TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { reduceMotion }, patience: patience)
    }

    /// Where `count` forward turns should end up, found by walking in a second view.
    private func locationAfter(_ count: Int, from fraction: Double? = nil) async throws -> ReaderLocation {
        let otherWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let walker = BookWebView(frame: view.frame)
        otherWindow.contentView = walker
        var location = try await walker.open(fixture("long.epub"), at: nil)
        if let fraction { location = try #require(await walker.go(toFraction: fraction)) }
        for _ in 0..<count { location = try #require(await walker.next()) }
        return location
    }

    /// Opens the long book on screen, as in the app, with the buffer full.
    private func openWithFullBuffer(at fraction: Double? = nil) async throws -> ReaderLocation {
        window.orderFrontRegardless()
        var location = try await view.open(fixture("long.epub"), at: nil)
        if let fraction { location = try #require(await view.go(toFraction: fraction)) }
        await cache.refresh(around: location)
        await cache.neighboursReady()
        return location
    }

    private func waitUntilDone(_ turns: TurnCoordinator) async throws {
        while turns.isTurning { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: Required by the plan

    @Test func oneLayerPerStrip() throws {
        _ = try preparedCurl()
        #expect(curl.stripLayers.count == 28)
        // Each hangs from the one before, so the page bends as a chain.
        for (earlier, later) in zip(curl.stripLayers, curl.stripLayers.dropFirst()) {
            #expect(later.superlayer === earlier)
        }
        #expect(curl.stripLayers.allSatisfy { $0 is CATransformLayer })
    }

    @Test func poseMatchesGeometry() throws {
        _ = try preparedCurl()
        curl.setProgress(0.25)
        let angles = CurlPose.angles(t: 0.25)
        var previous = 0.0
        for (strip, angle) in zip(curl.stripLayers, angles) {
            #expect(abs(relativeRotation(of: strip) - (angle - previous)) < 0.01)
            previous = angle
        }
    }

    // MARK: Faces

    @Test func stripsAreHingedOnTheirLeftEdges() throws {
        _ = try preparedCurl()
        let width = 500.0 / 28
        for (index, strip) in curl.stripLayers.enumerated() {
            #expect(strip.anchorPoint == CGPoint(x: 0, y: 0.5))
            #expect(abs(strip.position.x - (index == 0 ? 500 : width)) < 0.001)
        }
    }

    /// Together the faces show the whole bitmap in order. The back runs the other way along the chain.
    @Test func facesCoverTheirBitmapsInOrder() throws {
        _ = try preparedCurl()
        let slice = 1.0 / 28
        for (index, (front, back)) in curl.stripFaces.enumerated() {
            #expect(abs(front.contentsRect.minX - Double(index) * slice) < 0.0001)
            #expect(abs(front.contentsRect.width - slice) < 0.0001)
            #expect(abs(back.contentsRect.maxX - (1 - Double(index) * slice)) < 0.0001)
            #expect(abs(back.contentsRect.width - slice) < 0.0001)
            #expect(!front.isDoubleSided && !back.isDoubleSided)
        }
    }

    /// Smoothing a hinge leaves a visible line down the page there.
    @Test func onlyThePagesOutsideEdgesAreSmoothed() throws {
        _ = try preparedCurl()
        let sides: CAEdgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge]
        for (index, (front, back)) in curl.stripFaces.enumerated() {
            let isLast = index == curl.stripFaces.count - 1
            let frontShade = try #require(front.sublayers?.first)
            let backShade = try #require(back.sublayers?.first)
            for layer in [front, back, frontShade, backShade] {
                #expect(layer.allowsEdgeAntialiasing)
            }
            #expect(front.edgeAntialiasingMask.intersection(sides) == (isLast ? .layerRightEdge : []))
            #expect(back.edgeAntialiasingMask.intersection(sides) == (isLast ? .layerLeftEdge : []))
            #expect(frontShade.edgeAntialiasingMask == front.edgeAntialiasingMask)
            #expect(backShade.edgeAntialiasingMask == back.edgeAntialiasingMask)
        }
    }

    @Test func facesShowTheRightBitmaps() throws {
        let front = try spread(width: 1000, left: red, right: red)
        let back = try spread(width: 1000, left: blue, right: blue)
        curl.begin(.forward, front: front, back: back, beneathLeft: front, beneathRight: back)
        for faces in curl.stripFaces {
            #expect((faces.front.contents as! CGImage) === front)
            #expect((faces.back.contents as! CGImage) === back)
        }
    }

    @Test func facesDrawAtTheBitmapsScale() throws {
                // 1000 by 1400 pixels on a 500 by 700 point page.
        let half = try spread(width: 1000, height: 1400, left: red, right: red)
        curl.begin(.forward, front: half, back: half, beneathLeft: half, beneathRight: half)
        for faces in curl.stripFaces {
            #expect(faces.front.contentsScale == 2)
            #expect(faces.back.contentsScale == 2)
        }
        #expect(curl.beneathLayers.left?.contentsScale == 2)
        #expect(curl.beneathLayers.right?.contentsScale == 2)
    }

    /// Darkness at a face's spine-side and outer ends.
    private func shadeEnds(_ face: CALayer) throws -> (spine: CGFloat, outer: CGFloat) {
        let shade = try #require(face.sublayers?.first as? CAGradientLayer)
        let colors = try #require(shade.colors as? [CGColor])
        return (colors[0].alpha, colors[1].alpha)
    }

    @Test func shadeAndCastFollowTheProgress() throws {
        _ = try preparedCurl()
        curl.setProgress(0.5)
        for (front, back) in curl.stripFaces {
            #expect(abs(try shadeEnds(front).spine - 0.16) < 0.001)
            #expect(abs(try shadeEnds(front).outer - 0.16) < 0.001)
            #expect(abs(try shadeEnds(back).spine - 0.16) < 0.001)
            #expect(abs(try shadeEnds(back).outer - 0.16) < 0.001)
        }
        #expect(abs(Double(try #require(curl.castLayer).opacity) - 1) < 0.001)
        curl.setProgress(0.25)
        #expect(abs(Double(try #require(curl.castLayer).opacity) - CurlPose.cast(t: 0.25)) < 0.001)
    }

    /// Neighbours must agree at their hinge, or the strips show as bands.
    @Test func shadeIsContinuousAcrossHinges() throws {
        _ = try preparedCurl()
        curl.setProgress(0.25)
        let angles = CurlPose.angles(t: 0.25)
        for (index, (earlier, later)) in zip(curl.stripFaces, curl.stripFaces.dropFirst()).enumerated() {
            let hinge = CurlPose.shade(angle: (angles[index] + angles[index + 1]) / 2)
            #expect(abs(try shadeEnds(earlier.front).outer - hinge) < 0.0001)
            #expect(abs(try shadeEnds(later.front).spine - hinge) < 0.0001)
            #expect(abs(try shadeEnds(earlier.back).outer - hinge) < 0.0001)
            #expect(abs(try shadeEnds(later.back).spine - hinge) < 0.0001)
        }
        // And the shade does vary along the page at this point in the turn.
        let ends = (try shadeEnds(try #require(curl.stripFaces.first).front).spine,
                    try shadeEnds(try #require(curl.stripFaces.last).front).outer)
        #expect(abs(ends.0 - ends.1) > 0.05)
    }

    /// `CurlPose` stops 0.5 degrees short of flat, which would be a jump at the very start of a
    /// backward turn.
    @Test func aTurnBackwardStartsExactlyFlat() throws {
        #expect(CurlView.drawnAngles(t: 1).allSatisfy { $0 == -180 })
        let half = try spread(width: 1000, left: red, right: red)
        curl.begin(.backward, front: half, back: half, beneathLeft: half, beneathRight: half)
        #expect(curl.progress == 1)
        #expect(abs(abs(relativeRotation(of: try #require(curl.stripLayers.first))) - 180) < 0.001)
        for strip in curl.stripLayers.dropFirst() {
            #expect(abs(relativeRotation(of: strip)) < 0.001)
        }
    }

    /// Away from the very end, the page follows the approved geometry exactly, and getting flat
    /// is gradual.
    @Test func flatteningOnlyTouchesTheEnd() {
        for t in [0, 0.25, 0.5, 0.75, 0.94] {
            #expect(CurlView.drawnAngles(t: t) == CurlPose.angles(t: t))
        }
        let steps = stride(from: 0.95, through: 1, by: 0.01).map { CurlView.drawnAngles(t: $0)[0] }
        for (earlier, later) in zip(steps, steps.dropFirst()) {
            #expect(abs(later - earlier) < 0.2)
        }
    }

    @Test func clicksOnlyTurnPagesOnTheBooksEdges() {
        let desk = TrialDeskView(
            frame: NSRect(x: 0, y: 0, width: 1048, height: 620),
            bookFrame: NSRect(x: 34, y: 34, width: 980, height: 552))
        #expect(desk.turn(at: NSPoint(x: 40, y: 300)) == .backward)
        #expect(desk.turn(at: NSPoint(x: 1000, y: 300)) == .forward)
        #expect(desk.turn(at: NSPoint(x: 524, y: 300)) == nil)
        // The bare desk, on all sides.
        #expect(desk.turn(at: NSPoint(x: 10, y: 300)) == nil)
        #expect(desk.turn(at: NSPoint(x: 1040, y: 300)) == nil)
        #expect(desk.turn(at: NSPoint(x: 40, y: 10)) == nil)
        #expect(desk.turn(at: NSPoint(x: 1000, y: 610)) == nil)
    }

    @Test func perspectiveMatchesTheMockup() throws {
        _ = try preparedCurl()
        let stage = try #require(curl.stripLayers.first?.superlayer)
        #expect(abs(Double(stage.sublayerTransform.m34) + 1.0 / 2400) < 1e-9)
    }

    // MARK: Playing

    @Test func aFinishedPlayLandsFlatOnTheBackPage() async throws {
        let front = try spread(width: 1000, left: red, right: red)
        let back = try spread(width: 1000, left: blue, right: blue)
        let left = try spread(width: 1000, left: green, right: green)
        let right = try spread(width: 1000, left: yellow, right: yellow)
        curl.begin(.forward, front: front, back: back, beneathLeft: left, beneathRight: right)

        var finished = false
        curl.play(from: 0, to: 1) { finished = true }
        #expect(curl.isPlaying)
        #expect(!finished)
        curl.snapToEnd()
        #expect(finished)
        #expect(!curl.isPlaying)
        #expect(curl.stripLayers.isEmpty)
        // The turned page now lies flat, in place of what it landed on.
        #expect((curl.beneathLayers.left?.contents as! CGImage) === back)
        #expect((curl.beneathLayers.right?.contents as! CGImage) === right)
        #expect(curl.isShowing)

        curl.end()
        #expect(!curl.isShowing)
    }

    @Test func aPlayBackLandsFlatOnTheFrontPage() throws {
        let front = try spread(width: 1000, left: red, right: red)
        let back = try spread(width: 1000, left: blue, right: blue)
        let left = try spread(width: 1000, left: green, right: green)
        let right = try spread(width: 1000, left: yellow, right: yellow)
        curl.begin(.backward, front: front, back: back, beneathLeft: left, beneathRight: right)

        var finished = false
        curl.play(from: 1, to: 0) { finished = true }
        curl.snapToEnd()
        #expect(finished)
        #expect((curl.beneathLayers.left?.contents as! CGImage) === left)
        #expect((curl.beneathLayers.right?.contents as! CGImage) === front)
    }

    /// A window that's hidden or covered gets no display-link ticks, but the turn must still end.
    @Test func playFinishesWithoutADisplay() async throws {
        _ = try preparedCurl()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            curl.play(from: 0, to: 1) { continuation.resume() }
        }
        #expect(!curl.isPlaying)
    }

    // MARK: Cropping

    @Test func forwardImagesComeFromTheRightHalves() throws {
        let current = try spread(left: red, right: green)
        let next = try spread(left: blue, right: yellow)
        let pieces = try #require(TurnImages(.forward, current: current, target: next))
        #expect(colour(of: pieces.front) == [0, 255, 0])
        #expect(colour(of: pieces.back) == [0, 0, 255])
        #expect(colour(of: pieces.beneathLeft) == [255, 0, 0])
        #expect(colour(of: pieces.beneathRight) == [255, 255, 0])
    }

    @Test func backwardImagesAreTheReverse() throws {
        let current = try spread(left: red, right: green)
        let previous = try spread(left: blue, right: yellow)
        let pieces = try #require(TurnImages(.backward, current: current, target: previous))
        #expect(colour(of: pieces.front) == [255, 255, 0])
        #expect(colour(of: pieces.back) == [255, 0, 0])
        #expect(colour(of: pieces.beneathLeft) == [0, 0, 255])
        #expect(colour(of: pieces.beneathRight) == [0, 255, 0])
    }

    @Test func halvesCoverAnOddWidth() throws {
        let image = try spread(width: 1001, left: red, right: green)
        let pieces = try #require(TurnImages(.forward, current: image, target: image))
        #expect(pieces.beneathLeft.width + pieces.front.width == 1001)
    }

    // MARK: Turning: required by the plan

    @Test func noTurnPastEnds() async throws {
        let start = try await view.open(fixture("no-cover.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = coordinator()
        turns.turn(.backward)
        #expect(!turns.isTurning)
        #expect(curl.stripLayers.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.currentLocation?.cfi == start.cfi)

        let end = try #require(await view.go(toFraction: 1))
        #expect(end.isAtEnd)
        await cache.refresh(around: end)
        turns.turn(.forward)
        #expect(!turns.isTurning)
        #expect(curl.stripLayers.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.currentLocation?.cfi == end.cfi)
    }

    @Test func reduceMotionCrossfades() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = coordinator(reduceMotion: true)
        turns.turn(.forward)
        #expect(turns.isTurning)
        #expect(curl.isCrossfading)
        #expect(curl.stripLayers.isEmpty)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
        #expect(!curl.isShowing)
    }

    // MARK: Turning

    @Test func aTurnCurlsThenLands() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = coordinator()
        turns.turn(.forward)
        #expect(turns.isTurning)
        #expect(curl.isPlaying)
        #expect(curl.stripLayers.count == CurlPose.strips)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
        #expect(!curl.isShowing)
    }

    /// The curl must cover the web view until that shows the page the curl landed on.
    @Test func theCurlStaysUntilTheLandedPageIsShowing() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let promised = try #require(cache.image(for: .next))
        let turns = coordinator()
        turns.turn(.forward)
        curl.snapToEnd()
        while curl.isShowing {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(view.currentLocation?.cfi != start.cfi)
        let shown = try await snapshot()
        #expect(ImageDiff.fractionDifferent(shown, promised) < SpreadCacheTests.landingTolerance)
    }

    @Test func aKeypressDuringATurnSnapsItAndGoesOn() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = coordinator()
        turns.turn(.forward)
        #expect(curl.isPlaying)
        try await Task.sleep(for: .milliseconds(100))

        // Back is ready at once: going forward left the old spread in `previous`.
        turns.turn(.backward)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == start.cfi)
    }

    /// Long enough for a move to land, and well inside the curl it started.
    private static let midCurl: Duration = .milliseconds(200)

    @Test func aForwardPressDuringAForwardCurlStartsTheNextAtOnce() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(2)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.turn(.forward)
        let first = try #require(curl.stripLayers.first)
        try await Task.sleep(for: Self.midCurl)
        #expect(curl.isPlaying)

        turns.turn(.forward)
        #expect(curl.isPlaying)
        #expect(curl.direction == .forward)
        #expect(curl.progress == 0)
        #expect(curl.stripLayers.count == CurlPose.strips)
        #expect(curl.stripLayers.first !== first)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    @Test func aBackwardPressDuringABackwardCurlStartsTheNextAtOnce() async throws {
        defer { window.orderOut(nil) }
        let start = try await openWithFullBuffer(at: 0.5)
        let turns = coordinator()
        turns.turn(.backward)
        let first = try #require(curl.stripLayers.first)
        try await Task.sleep(for: Self.midCurl)
        #expect(curl.isPlaying)

        turns.turn(.backward)
        #expect(curl.isPlaying)
        #expect(curl.direction == .backward)
        #expect(curl.progress == 1)
        #expect(curl.stripLayers.first !== first)
        try await waitUntilDone(turns)

        // Two forward turns should come straight back.
        _ = await view.next()
        let back = try #require(await view.next())
        #expect(back.cfi == start.cfi)
    }

    /// Before the first move has landed the slots can't be trusted, so this one can't curl yet.
    @Test func aSecondPressBeforeTheLandingStillCounts() async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(2)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        turns.turn(.forward)
        turns.turn(.forward)
        // The first has snapped to its end, and lies flat over the book.
        #expect(!curl.isPlaying)
        #expect(curl.stripLayers.isEmpty)
        #expect(curl.isShowing)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    private func expectEveryPressCurls(every gap: Duration, turnCount: Int) async throws {
        defer { window.orderOut(nil) }
        let expected = try await locationAfter(turnCount)
        _ = try await openWithFullBuffer()
        let turns = coordinator()
        var curls = 0
        for index in 0..<turnCount {
            let pressed = ContinuousClock.now
            let promised = try #require(cache.image(for: .next), "No image ready for turn \(index)")
            turns.turn(.forward)
            if curl.isPlaying && curl.stripLayers.count == CurlPose.strips { curls += 1 }
            try await Task.sleep(until: pressed + Self.midCurl + .milliseconds(100))
            let shown = try await snapshot()
            let difference = ImageDiff.fractionDifferent(shown, promised)
            #expect(difference < SpreadCacheTests.landingTolerance, "Turn \(index) landed \(difference) away")
            try await Task.sleep(until: pressed + gap)
        }
        #expect(curls == turnCount)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
    }

    @Test func aPressEveryPointFourSecondsAlwaysCurls() async throws {
        try await expectEveryPressCurls(every: .milliseconds(400), turnCount: 10)
    }

    @Test func aPressEverySecondAlwaysCurls() async throws {
        try await expectEveryPressCurls(every: .seconds(1), turnCount: 4)
    }

    /// A press must never look ignored, whatever the buffer has.
    @Test func aPressThatOutrunsTheBufferChangesThePageQuickly() async throws {
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        let pressed = ContinuousClock.now
        turns.turn(.forward)
        while view.currentLocation?.cfi == start.cfi {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ContinuousClock.now - pressed < .milliseconds(250))
        #expect(curl.stripLayers.isEmpty)
    }

    /// A snapshot that never answers mustn't leave a curl lying over the book.
    @Test func theCurlComesOffIfThePageNeverReportsPainted() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = TurnCoordinator(
            book: view, cache: cache, curl: curl, reduceMotion: { false }, takeSnapshot: { _, _ in })
        turns.turn(.forward)
        curl.snapToEnd()
        #expect(curl.isShowing)
        let deadline = ContinuousClock.now + .seconds(5)
        while curl.isShowing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!curl.isShowing)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    @Test func turningBackPlaysFromTheEnd() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let there = try #require(await view.go(toFraction: 0.5))
        await cache.refresh(around: there)
        let turns = coordinator()
        turns.turn(.backward)
        #expect(curl.direction == .backward)
        #expect(curl.progress == 1)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != there.cfi)
    }

    /// Nothing's ready, so there's nothing right to curl with.
    @Test func aTurnWithoutImagesShowsNoCurlAndStillHappens() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        let turns = coordinator()
        turns.turn(.forward)
        #expect(turns.isTurning)
        #expect(curl.stripLayers.isEmpty)
        #expect(!curl.isShowing)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    /// Given the patience to outlast a whole refresh, the turn waits for it and gets its curl.
    @Test func aTurnWaitsForNeighboursThatAreComing() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        let refresh = Task { await cache.refresh(around: start) }
        let turns = coordinator(patience: .seconds(30))
        turns.turn(.forward)
        #expect(curl.stripLayers.isEmpty)
        var curled = false
        while turns.isTurning {
            if !curl.stripLayers.isEmpty { curled = true }
            try await Task.sleep(for: .milliseconds(5))
        }
        await refresh.value
        #expect(curled)
        #expect(view.currentLocation?.cfi != start.cfi)
    }

    /// Every press counts, however few of them got a curl.
    @Test func aBurstLandsWhereItShould() async throws {
        let expected = try await locationAfter(8)

        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let turns = coordinator()
        for _ in 0..<8 {
            turns.turn(.forward)
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(!curl.isShowing)
    }

    /// The first press's landing is what shows the second has nowhere to go.
    @Test func aTurnPastTheEndAfterALandingDoesNothing() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        let end = try #require(await view.go(toFraction: 1))
        let nearEnd = try #require(await view.previous())
        #expect(end.isAtEnd && !nearEnd.isAtEnd)
        await cache.refresh(around: nearEnd)
        let turns = coordinator()
        turns.turn(.forward)
        turns.turn(.forward)
        try await waitUntilDone(turns)
        #expect(view.currentLocation?.isAtEnd == true)
        #expect(!curl.isShowing)
    }

    private func snapshot() async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            view.webView.takeSnapshot(with: nil) { image, error in
                if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: error ?? BookWebViewError.timedOut)
                }
            }
        }
    }
}
