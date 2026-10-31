import AppKit
import Foundation
import Testing
import WebKit
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// Compares two images pixel by pixel.
enum ImageDiff {
    /// A difference this small in a channel, out of 255, is colour rounding rather than a change.
    private static let tolerance = 4

    /// The share of pixels that differ, from 0 to 1. Images of different sizes differ completely.
    static func fractionDifferent(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height, a.width > 0, a.height > 0,
              let first = rgba(a), let second = rgba(b)
        else { return 1 }
        var different = 0
        for pixel in stride(from: 0, to: first.count, by: 4) {
            for channel in pixel..<(pixel + 4)
            where abs(Int(first[channel]) - Int(second[channel])) > tolerance {
                different += 1
                break
            }
        }
        return Double(different) / Double(a.width * a.height)
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: bytes.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? pixels : nil
    }
}

/// The visible view also sits in a window that's never shown, except in the test that shows it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct SpreadCacheTests {
    static let landingTolerance = 0.002

    let window: NSWindow
    let view: BookWebView
    let cache: SpreadCache

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
        cache = SpreadCache(visible: view)
    }

    // MARK: Required by the plan

    @Test func nextDiffersFromCurrent() async throws {
        let location = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: location)
        let current = try #require(cache.image(for: .current))
        let next = try #require(cache.image(for: .next))
        #expect(ImageDiff.fractionDifferent(current, next) > 0.01)
    }

    @Test func landingMatchesPreviewMidChapter() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try #require(await view.go(toFraction: 0.5))
        let before = try #require(view.currentLocation)
        try await expectLanding(.forward)
        #expect(view.currentLocation?.chapterTitle == before.chapterTitle)
    }

    @Test func landingMatchesPreviewAcrossAChapterBoundary() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        try await walkToLastSpreadOfFirstChapter()
        let before = try #require(view.currentLocation?.chapterTitle)
        try await expectLanding(.forward)
        #expect(view.currentLocation?.chapterTitle != before)
    }

    @Test func landingMatchesPreviewOnAHalfEmptyLastSpread() async throws {
        _ = try await view.open(fixture("spreads.epub"), at: nil)
        var found = false
        for _ in 0..<60 {
            let location = try #require(view.currentLocation)
            await cache.refresh(around: location)
            guard let next = cache.image(for: .next) else { break }
            if isHalfEmpty(next) {
                found = true
                try await expectLanding(.forward)
                #expect(try await isHalfEmpty(snapshot(view)))
                let chapter = view.currentLocation?.chapterTitle
                // It really is the end of its chapter.
                try await expectLanding(.forward)
                #expect(view.currentLocation?.chapterTitle != chapter)
                break
            }
            await cache.commit(.forward)
        }
        #expect(found, "The fixture should have a half-empty spread")
    }

    @Test func noPreviousAtStart() async throws {
        let start = try await view.open(fixture("no-cover.epub"), at: nil)
        #expect(start.isAtStart)
        await cache.refresh(around: start)
        #expect(cache.image(for: .previous) == nil)
        #expect(cache.image(for: .next) != nil)

        let end = try #require(await view.go(toFraction: 1))
        #expect(end.isAtEnd)
        await cache.refresh(around: end)
        #expect(cache.image(for: .next) == nil)
        #expect(cache.image(for: .previous) != nil)
    }

    // MARK: Landing in other conditions

    @Test func goingBackMatchesPreview() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try #require(await view.go(toFraction: 0.5))
        try await expectLanding(.backward)
    }

    @Test func goingBackAcrossAChapterBoundaryMatchesPreview() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        try await walkToLastSpreadOfFirstChapter()
        _ = try #require(await view.next())
        let chapter = view.currentLocation?.chapterTitle
        try await expectLanding(.backward)
        #expect(view.currentLocation?.chapterTitle != chapter)
    }

    /// Fonts and large images are what a snapshot taken too early would miss.
    @Test func everyLandingMatchesInABookWithAFontAndImages() async throws {
        _ = try await view.open(fixture("late-resources.epub"), at: nil)
        let fontLoaded = try await view.call(
            """
            const doc = readmeBridge.currentDocument()
            await doc.fonts.ready
            return [...doc.fonts].some(font => font.family.includes('Fixture') && font.status === 'loaded')
            """,
            as: Bool.self)
        #expect(fontLoaded == true)

        var turns = 0
        while try #require(view.currentLocation).isAtEnd == false && turns < 60 {
            try await expectLanding(.forward, thenStaysPut: true)
            turns += 1
        }
        #expect(turns > 3)
        #expect(try #require(view.currentLocation).isAtEnd)
        while try #require(view.currentLocation).isAtStart == false && turns > 0 {
            try await expectLanding(.backward, thenStaysPut: true)
            turns -= 1
        }
    }

    @Test func landingMatchesWithStylesApplied() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let css = "html, body { background: rgb(240, 225, 190) !important } body { font-size: 130% !important }"
        await view.applyStyles(css: css, columns: 2)
        try await walkToLastSpreadOfFirstChapter()
        try await expectLanding(.forward)
        try await expectLanding(.forward)
    }

    @Test func oneColumnLandingMatches() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        await view.applyStyles(css: "", columns: 1)
        _ = try #require(await view.go(toFraction: 0.5))
        try await expectLanding(.forward)
    }

    @Test func portraitLandingMatches() async throws {
        window.setContentSize(NSSize(width: 600, height: 900))
        _ = try await view.open(fixture("spreads.epub"), at: nil)
        for _ in 0..<4 { try await expectLanding(.forward) }
    }

    /// The real app's arrangement: a window that's on screen beside one that never is.
    @Test func landingMatchesFromAWindowOnScreen() async throws {
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        _ = try await view.open(fixture("late-resources.epub"), at: nil)
        for _ in 0..<4 { try await expectLanding(.forward) }
    }

    // MARK: Following the visible view

    @Test func imagesAreAtTheBackingStoreScale() async throws {
        let location = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: location)
        let scale = window.backingScaleFactor
        for slot in [SpreadSlot.current, .next] {
            let image = try #require(cache.image(for: slot))
            #expect(image.width == Int(view.bounds.width * scale))
            #expect(image.height == Int(view.bounds.height * scale))
        }
    }

    @Test func resizingTheVisibleViewResizesThePreviews() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try #require(await view.go(toFraction: 0.5))
        try await expectLanding(.forward)

        window.setContentSize(NSSize(width: 1300, height: 800))
        try await Task.sleep(for: .milliseconds(600))
        try await expectLanding(.forward)
        #expect(try #require(cache.image(for: .current)).width == Int(1300 * window.backingScaleFactor))
    }

    @Test func changingStylesRedrawsThePreviews() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let location = try #require(await view.go(toFraction: 0.5))
        await cache.refresh(around: location)
        let before = try #require(cache.image(for: .next))

        await view.applyStyles(css: "body { font-size: 170% !important }", columns: 2)
        await cache.refresh(around: try #require(view.currentLocation))
        let after = try #require(cache.image(for: .next))
        #expect(ImageDiff.fractionDifferent(before, after) > 0.01)
        try await expectLanding(.forward)
    }

    @Test func openingAnotherBookFollowsIt() async throws {
        let first = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: first)
        let second = try await view.open(fixture("spreads.epub"), at: nil)
        await cache.refresh(around: second)
        try await expectLanding(.forward)
    }

    @Test func jumpingDropsTheOldNeighbours() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let far = try #require(await view.go(toFraction: 0.7))
        let refresh = Task { await cache.refresh(around: far) }
        // Nothing from the old place is on offer while the new one renders.
        #expect(cache.image(for: .previous) == nil)
        await refresh.value
        try await expectLanding(.forward)
    }

    // MARK: Settling

    /// A slow font or image is hard to arrange for real, so these stand in for a page that's still
    /// waiting on one, and check that `settle` doesn't return until it's in.
    @Test func settleWaitsForFonts() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try await view.call(
            """
            const { fonts } = readmeBridge.currentDocument()
            globalThis.waitedFor = false
            Object.defineProperty(fonts, 'ready', { configurable: true, value: new Promise(resolve => {
                setTimeout(() => { globalThis.waitedFor = true; resolve() }, 1000)
            }) })
            """,
            as: Bool.self)
        await view.settle()
        #expect(try await view.call("return globalThis.waitedFor", as: Bool.self) == true)
    }

    @Test func settleWaitsForImagesToDecode() async throws {
        _ = try await view.open(fixture("late-resources.epub"), at: nil)
        _ = try await view.call(
            """
            const image = readmeBridge.currentDocument().querySelector('img')
            globalThis.waitedFor = false
            image.decode = () => new Promise(resolve => {
                setTimeout(() => { globalThis.waitedFor = true; resolve() }, 1000)
            })
            """,
            as: Bool.self)
        await view.settle()
        #expect(try await view.call("return globalThis.waitedFor", as: Bool.self) == true)
    }

    @Test func settleGivesUpOnAFontThatNeverArrives() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try await view.call(
            """
            const { fonts } = readmeBridge.currentDocument()
            Object.defineProperty(fonts, 'ready', { configurable: true, value: new Promise(() => {}) })
            """,
            as: Bool.self)
        let started = ContinuousClock.now
        await view.settle()
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await view.next() != nil)
    }

    @Test func settlePaginatesAroundContentThatArrivedLate() async throws {
        _ = try await view.open(fixture("spreads.epub"), at: nil)
        let pages = "return document.querySelector('foliate-view').renderer.pages"
        let before = try #require(try await view.call(pages, as: Int.self))
        _ = try await view.call(
            """
            const doc = readmeBridge.currentDocument()
            const late = doc.createElement('div')
            late.style.height = '5000px'
            doc.body.prepend(late)
            """,
            as: Bool.self)
        await view.settle()
        #expect(try #require(try await view.call(pages, as: Int.self)) > before)
    }

    @Test func settleWaitsForARelayoutAfterAResize() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let width = "return parseFloat(readmeBridge.currentDocument().documentElement.style.columnWidth)"
        let before = try #require(try await view.call(width, as: Double.self))
        window.setContentSize(NSSize(width: 1300, height: 800))
        await view.settle()
        #expect(try #require(try await view.call(width, as: Double.self)) > before)
    }

    // MARK: Committing

    @Test func commitRotatesAndRefreshesWithoutWaiting() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        await cache.neighboursReady()
        let oldCurrent = try #require(cache.image(for: .current))
        let oldNext = try #require(cache.image(for: .next))
        let oldAfterNext = try #require(cache.image(for: .afterNext))

        await cache.commit(.forward)
        #expect(cache.image(for: .previous) === oldCurrent)
        #expect(cache.image(for: .current) === oldNext)
        // Promoted at once, so the next turn needn't wait for anything.
        #expect(cache.image(for: .next) === oldAfterNext)

        await cache.neighboursReady()
        #expect(cache.image(for: .afterNext) != nil)
        // Only what's missing was rendered.
        #expect(cache.image(for: .previous) === oldCurrent)
        #expect(cache.image(for: .current) === oldNext)
        #expect(cache.image(for: .next) === oldAfterNext)
    }

    /// The images promoted by a landing were rendered from further off, and must be just as true.
    @Test func promotedImagesMatchTheirLandings() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        try await walkToLastSpreadOfFirstChapter()
        await cache.refresh(around: try #require(view.currentLocation))
        for direction in [TurnDirection.forward, .forward, .forward, .backward, .backward, .backward] {
            await cache.neighboursReady()
            let promised = try #require(cache.image(for: direction == .forward ? .next : .previous))
            await cache.commit(direction)
            let difference = ImageDiff.fractionDifferent(try await snapshot(view), promised)
            #expect(difference < Self.landingTolerance, "Landed \(difference) from its preview")
        }
    }

    @Test func theFurtherSlotsAreNilPastTheEnds() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        let end = try #require(await view.go(toFraction: 1))
        await cache.refresh(around: end)
        await cache.neighboursReady()
        #expect(cache.image(for: .next) == nil)
        #expect(cache.image(for: .afterNext) == nil)
        #expect(cache.image(for: .beforePrevious) != nil)
    }

    /// The buffer's cost: five whole spreads at backing scale, on a window the size of a big screen.
    @Test func theBufferIsFiveSpreads() async throws {
        window.setContentSize(NSSize(width: 1512, height: 982))
        _ = try await view.open(fixture("long.epub"), at: nil)
        let there = try #require(await view.go(toFraction: 0.5))
        await cache.refresh(around: there)
        await cache.neighboursReady()
        let slots: [SpreadSlot] = [.current, .next, .previous, .afterNext, .beforePrevious]
        let images = try slots.map { try #require(cache.image(for: $0)) }
        let scale = window.backingScaleFactor
        #expect(images.allSatisfy { $0.width == Int(1512 * scale) && $0.height == Int(982 * scale) })
        let spreadBytes = images[0].bytesPerRow * images[0].height
        #expect(cache.bufferedBytes == 5 * spreadBytes)
    }

    @Test func commitPastTheEndsChangesNothing() async throws {
        let start = try await view.open(fixture("no-cover.epub"), at: nil)
        await cache.refresh(around: start)
        let current = try #require(cache.image(for: .current))
        let next = try #require(cache.image(for: .next))

        await cache.commit(.backward)
        await cache.neighboursReady()
        #expect(view.currentLocation?.cfi == start.cfi)
        #expect(cache.image(for: .current) === current)
        #expect(cache.image(for: .next) === next)
        #expect(cache.image(for: .previous) == nil)
    }

    @Test func commitBeforeAnyRefreshIsSafe() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        await cache.commit(.forward)
        #expect(cache.image(for: .current) != nil)
        await cache.neighboursReady()
        try await expectImagesMatchTheBook()
    }

    /// Task 6 fires turns this far apart.
    @Test func rapidCommitsLandCorrectly() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        // Where 12 turns should end up, found by walking in a second view.
        let otherWindow = NSWindow(
            contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        let walker = BookWebView(frame: view.frame)
        otherWindow.contentView = walker
        var expected = try await walker.open(fixture("long.epub"), at: nil)
        for _ in 0..<12 { expected = try #require(await walker.next()) }

        await cache.refresh(around: try #require(view.currentLocation))
        var turns: [Task<Void, Never>] = []
        for _ in 0..<12 {
            turns.append(Task { await cache.commit(.forward) })
            try await Task.sleep(for: .milliseconds(50))
        }
        for turn in turns { await turn.value }

        #expect(view.currentLocation?.cfi == expected.cfi)
        #expect(cache.image(for: .current) != nil)
        await cache.neighboursReady()
        try await expectImagesMatchTheBook()
        try await expectLanding(.forward)
        try await expectLanding(.backward)
    }

    @Test func commitsInterruptingARefreshLeaveNothingStale() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        _ = try #require(await view.go(toFraction: 0.3))
        let location = try #require(view.currentLocation)
        for delay in [0, 20, 80, 200, 400] {
            let refresh = Task { await cache.refresh(around: location) }
            try await Task.sleep(for: .milliseconds(delay))
            await cache.commit(.forward)
            await cache.commit(.backward)
            await refresh.value
            await cache.neighboursReady()
            #expect(view.currentLocation?.cfi == location.cfi)
            try await expectImagesMatchTheBook()
        }
    }

    /// The image waiting in the slot is for somewhere the turn didn't go, so it mustn't be used.
    @Test func commitAfterAnUnreportedMoveDropsTheImages() async throws {
        let start = try await view.open(fixture("long.epub"), at: nil)
        await cache.refresh(around: start)
        let staleNext = try #require(cache.image(for: .next))
        _ = try #require(await view.go(toFraction: 0.5))

        await cache.commit(.forward)
        #expect(cache.image(for: .current) !== staleNext)
        await cache.neighboursReady()
        try await expectImagesMatchTheBook()
    }

    /// A render stopped mid-move mustn't leave the next one misreading where the offscreen view is.
    @Test func replacingARenderMidWayLeavesTheRightImages() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        var there = try #require(await view.go(toFraction: 0.3))
        for delay in [150, 350, 550] {
            let earlier = Task { await cache.refresh(around: there) }
            try await Task.sleep(for: .milliseconds(delay))
            there = try #require(await view.next())
            await cache.refresh(around: there)
            await earlier.value
            try await expectImagesMatchTheBook()
        }
    }

    @Test func directionChangesInABurstLandCorrectly() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let location = try #require(await view.go(toFraction: 0.5))
        await cache.refresh(around: location)
        let turns = [TurnDirection.forward, .forward, .backward, .forward, .backward, .backward].map { direction in
            Task { await cache.commit(direction) }
        }
        for turn in turns { await turn.value }
        await cache.neighboursReady()
        #expect(view.currentLocation?.cfi == location.cfi)
        try await expectImagesMatchTheBook()
    }

    // MARK: Helpers

    /// Refreshes, turns, then compares the real page with the preview it was promised.
    private func expectLanding(
        _ direction: TurnDirection, thenStaysPut: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let before = try #require(view.currentLocation, sourceLocation: sourceLocation)
        await cache.refresh(around: before)
        let leaving = try #require(cache.image(for: .current), sourceLocation: sourceLocation)
        let preview = try #require(
            cache.image(for: direction == .forward ? .next : .previous), sourceLocation: sourceLocation)
        await cache.commit(direction)
        #expect(view.currentLocation?.cfi != before.cfi, sourceLocation: sourceLocation)

        let landed = try await snapshot(view)
        let difference = ImageDiff.fractionDifferent(landed, preview)
        #expect(
            difference < Self.landingTolerance,
            "Landed page differs from its preview by \(difference)", sourceLocation: sourceLocation)
        #expect(ImageDiff.fractionDifferent(leaving, landed) > 0.01, sourceLocation: sourceLocation)

        if thenStaysPut {
            // A page still settling would pass above and jump a moment later.
            try await Task.sleep(for: .milliseconds(400))
            let later = ImageDiff.fractionDifferent(try await snapshot(view), preview)
            #expect(later < Self.landingTolerance, "The page later differs by \(later)", sourceLocation: sourceLocation)
        }
    }

    /// Checks each slot against the real spread, by going there in the visible view and back.
    private func expectImagesMatchTheBook(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let here = try #require(view.currentLocation, sourceLocation: sourceLocation)
        let current = try #require(cache.image(for: .current), sourceLocation: sourceLocation)
        let next = try #require(cache.image(for: .next), sourceLocation: sourceLocation)
        let previous = try #require(cache.image(for: .previous), sourceLocation: sourceLocation)

        await view.settle()
        var difference = ImageDiff.fractionDifferent(try await snapshot(view), current)
        #expect(difference < Self.landingTolerance, "current differs by \(difference)", sourceLocation: sourceLocation)

        _ = await view.next()
        await view.settle()
        difference = ImageDiff.fractionDifferent(try await snapshot(view), next)
        #expect(difference < Self.landingTolerance, "next differs by \(difference)", sourceLocation: sourceLocation)

        _ = await view.go(toCFI: here.cfi)
        _ = await view.previous()
        await view.settle()
        difference = ImageDiff.fractionDifferent(try await snapshot(view), previous)
        #expect(difference < Self.landingTolerance, "previous differs by \(difference)", sourceLocation: sourceLocation)

        _ = await view.go(toCFI: here.cfi)
        await view.settle()
    }

    private func walkToLastSpreadOfFirstChapter() async throws {
        let chapter = try #require(view.currentLocation?.chapterTitle)
        for _ in 0..<40 {
            guard let location = await view.next() else { break }
            if location.chapterTitle != chapter { break }
        }
        #expect(view.currentLocation?.chapterTitle != chapter)
        _ = try #require(await view.previous())
        #expect(view.currentLocation?.chapterTitle == chapter)
    }

    private func snapshot(_ view: BookWebView) async throws -> CGImage {
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

    /// Text on the left page and none at all on the right.
    private func isHalfEmpty(_ image: CGImage) -> Bool {
        let half = image.width / 2
        let left = image.cropping(to: CGRect(x: 0, y: 0, width: half, height: image.height))
        let right = image.cropping(to: CGRect(x: half, y: 0, width: half, height: image.height))
        guard let left, let right else { return false }
        return darkFraction(left) > 0.005 && darkFraction(right) == 0
    }

    private func darkFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(pixels.lazy.filter { $0 < 128 }.count) / Double(pixels.count)
    }
}

@Suite struct ImageDiffTests {
    private func image(width: Int = 10, height: Int = 10, paint: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        paint(context)
        return try #require(context.makeImage())
    }

    @Test func identicalImagesDoNotDiffer() throws {
        let a = try image { _ in }
        #expect(ImageDiff.fractionDifferent(a, a) == 0)
    }

    @Test func countsTheShareOfPixelsThatDiffer() throws {
        let a = try image { _ in }
        let b = try image { context in
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 5, height: 2))
        }
        #expect(ImageDiff.fractionDifferent(a, b) == 0.1)
    }

    @Test func differentSizesDifferCompletely() throws {
        let a = try image { _ in }
        let b = try image(width: 11) { _ in }
        #expect(ImageDiff.fractionDifferent(a, b) == 1)
    }
}
