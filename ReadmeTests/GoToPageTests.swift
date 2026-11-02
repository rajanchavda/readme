import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// What a page number typed into the go-to-page field means.
@Suite struct GoToPageTests {
    @Test func aPageIsWhereItsTextBegins() {
        #expect(GoToPage.fraction(forTyped: "1", pageCount: 100) == 0)
        #expect(GoToPage.fraction(forTyped: "51", pageCount: 100) == 0.5)
        #expect(GoToPage.fraction(forTyped: " 51 ", pageCount: 100) == 0.5)
    }

    @Test func onlyAWholeNumberIsAPage() {
        #expect(GoToPage.fraction(forTyped: "", pageCount: 100) == nil)
        #expect(GoToPage.fraction(forTyped: "  ", pageCount: 100) == nil)
        #expect(GoToPage.fraction(forTyped: "twelve", pageCount: 100) == nil)
        #expect(GoToPage.fraction(forTyped: "12.5", pageCount: 100) == nil)
        #expect(GoToPage.fraction(forTyped: "12a", pageCount: 100) == nil)
    }

    @Test func aPageOutsideTheBookIsTheNearestOne() {
        #expect(GoToPage.fraction(forTyped: "0", pageCount: 100) == 0)
        #expect(GoToPage.fraction(forTyped: "-4", pageCount: 100) == 0)
        #expect(GoToPage.fraction(forTyped: "100", pageCount: 100) == 0.99)
        #expect(GoToPage.fraction(forTyped: "5000", pageCount: 100) == 0.99)
        #expect(GoToPage.fraction(forTyped: "99999999999999999999999", pageCount: 100) == 0.99)
    }

    @Test func aBookWithNoPagesHasNowhereToGo() {
        #expect(GoToPage.fraction(forTyped: "1", pageCount: 0) == nil)
    }

    @Test func theFieldShowsThePageAndTotal() {
        let english = Locale(identifier: "en_US")
        #expect(GoToPage.placeholder(page: 214, pageCount: 1240, locale: english) == "214 of 1,240")
        #expect(GoToPage.placeholder(page: 1, pageCount: 9, locale: english) == "1 of 9")
    }
}

/// The jumps, against a real book: they land where they say, play no curl, and leave the next turn
/// curling from the right place. The book is on screen, as in the app.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct PageShortcutTests {
    let window: NSWindow
    let view: BookWebView
    let cache: SpreadCache
    let curl: CurlView
    let turns: TurnCoordinator

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
        turns = TurnCoordinator(book: view, cache: cache, curl: curl, reduceMotion: { false })
    }

    @Test func aLocationKnowsItsPage() async throws {
        defer { window.orderOut(nil) }
        let start = try await open()
        #expect(start.page == 1)
        #expect(start.pageCount > 20)
        let later = try #require(await view.go(toFraction: 0.5))
        #expect(later.pageCount == start.pageCount)
        #expect(abs(Double(later.page) - Double(start.pageCount) / 2) <= 3)
    }

    @Test func goingToTheEndLandsOnTheLastSpread() async throws {
        defer { window.orderOut(nil) }
        _ = try await open(at: 0.3)
        let end = try #require(await turns.jump { await view.goToEnd() })
        #expect(end.isAtEnd)
        #expect(view.currentLocation?.isAtEnd == true)
        #expect(!curl.isShowing, "The jump played a curl")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook([.backward, .forward])
    }

    @Test func goingToTheStartLandsOnTheFirstSpread() async throws {
        defer { window.orderOut(nil) }
        _ = try await open(at: 0.6)
        let start = try #require(await turns.jump { await view.goToStart() })
        #expect(start.isAtStart)
        #expect(start.page == 1)
        #expect(!curl.isShowing, "The jump played a curl")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook([.forward, .backward])
    }

    @Test func goingToATypedPageShowsIt() async throws {
        defer { window.orderOut(nil) }
        let start = try await open()
        let wanted = start.pageCount / 2
        let fraction = try #require(GoToPage.fraction(forTyped: String(wanted), pageCount: start.pageCount))
        let there = try #require(await turns.jump { await view.go(toFraction: fraction) })
        // The spread that holds the start of the page, which can begin a page or so before it.
        #expect(there.page <= wanted && there.page >= wanted - 2, "Went to \(there.page) for \(wanted)")
        #expect(!curl.isShowing, "The jump played a curl")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook([.forward, .backward])
    }

    @Test func aPageNumberSurvivesAFontSizeChange() async throws {
        defer { window.orderOut(nil) }
        var settings = ReaderSettings()
        await view.applyStyles(css: ReadingCSS.css(settings, theme: .paper, fullscreen: false), columns: 2)
        let start = try await open()
        let fraction = try #require(GoToPage.fraction(forTyped: "120", pageCount: start.pageCount))
        let there = try #require(await turns.jump { await view.go(toFraction: fraction) })
        settings.fontSize += 6
        await view.applyStyles(css: ReadingCSS.css(settings, theme: .paper, fullscreen: false), columns: 2)
        let after = try #require(view.currentLocation)
        #expect(after.pageCount == there.pageCount)
        #expect(after.page == there.page, "Page \(there.page) became \(after.page)")
    }

    /// The jump waits for the turn to land, then takes the curl off, so the curl never plays out over
    /// the jump's place, and the book stays where the jump took it.
    @Test func aJumpDuringACurlEndsItAndStays() async throws {
        defer { window.orderOut(nil) }
        _ = try await open(at: 0.3)
        turns.turn(.forward)
        try #require(curl.isPlaying)
        let end = try #require(await turns.jump { await view.goToEnd() })
        #expect(end.isAtEnd)
        #expect(!curl.isShowing, "The curl was left playing over the jump's place")
        try await waitWhile { turns.isTurning }
        #expect(view.currentLocation?.cfi == end.cfi)
        await cache.neighboursReady()
        try await expectCurrentSlotMatchesTheBook()
        try await expectCurlsMatchTheBook([.backward])
    }

    /// A turn pressed while a jump is on its way turns from where the jump lands, however long the
    /// jump takes. This one takes longer than a press waits for a move to land.
    @Test func aTurnDuringAJumpFollowsIt() async throws {
        defer { window.orderOut(nil) }
        _ = try await open(at: 0.6)
        let jump = Task {
            await turns.jump { [view] in
                try? await Task.sleep(for: .milliseconds(400))
                return await view.goToStart()
            }
        }
        await Task.yield()
        turns.turn(.forward)
        let start = try #require(await jump.value)
        #expect(start.isAtStart)
        try await waitWhile { turns.isTurning }
        let here = try #require(view.currentLocation)
        #expect(!here.isAtStart, "The turn was lost")
        #expect(here.fraction < 0.05, "The turn went before the jump, to \(here.fraction)")
        await cache.neighboursReady()
        try await expectCurlsMatchTheBook([.forward])
    }

    // MARK: Helpers

    private func open(at fraction: Double? = nil) async throws -> ReaderLocation {
        window.orderFrontRegardless()
        var location = try await view.open(fixture("long.epub"), at: nil)
        if let fraction { location = try #require(await view.go(toFraction: fraction)) }
        await cache.refresh(around: location)
        await cache.neighboursReady()
        return location
    }

    private func waitWhile(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The images a curl started with.
    private struct Started {
        var front: CGImage
        var back: CGImage
        var beneathLeft: CGImage?
        var beneathRight: CGImage?
    }

    private func started() -> Started? {
        guard let faces = curl.stripFaces.first else { return nil }
        return Started(
            front: faces.front.contents as! CGImage, back: faces.back.contents as! CGImage,
            beneathLeft: curl.beneathLayers.left?.contents as! CGImage?,
            beneathRight: curl.beneathLayers.right?.contents as! CGImage?)
    }

    /// Each turn must curl, from the spread on screen to the one it lands on.
    private func expectCurlsMatchTheBook(
        _ directions: [TurnDirection], sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for direction in directions {
            let before = try await snapshot()
            turns.turn(direction)
            var seen = started()
            while turns.isTurning {
                if seen == nil { seen = started() }
                try await Task.sleep(for: .milliseconds(1))
            }
            let after = try await snapshot()
            let curled = try #require(seen, "The \(direction) turn didn't curl", sourceLocation: sourceLocation)
            let expected = try #require(TurnImages(direction, current: before, target: after), sourceLocation: sourceLocation)
            let pairs: [(String, CGImage?, CGImage)] = [
                ("front", curled.front, expected.front), ("back", curled.back, expected.back),
                ("beneath left", curled.beneathLeft, expected.beneathLeft),
                ("beneath right", curled.beneathRight, expected.beneathRight),
            ]
            for (name, image, wanted) in pairs {
                let image = try #require(image, "No \(name) image", sourceLocation: sourceLocation)
                let difference = ImageDiff.fractionDifferent(image, wanted)
                #expect(
                    difference < SpreadCacheTests.landingTolerance,
                    "The \(direction) curl's \(name) differs from the book by \(difference)",
                    sourceLocation: sourceLocation)
            }
            await cache.neighboursReady()
        }
    }

    private func expectCurrentSlotMatchesTheBook(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let current = try #require(cache.image(for: .current), sourceLocation: sourceLocation)
        let difference = ImageDiff.fractionDifferent(current, try await snapshot())
        #expect(difference < SpreadCacheTests.landingTolerance, "current differs by \(difference)", sourceLocation: sourceLocation)
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

/// The window's own handling: the contents, and jumps against restyles.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct ReaderJumpTests {
    /// The font change's restyle was asked for first, but the jump is the newer place.
    @Test func aRestyleUnderwayDoesNotUndoAJump() async throws {
        let saved = UserDefaults.standard.data(forKey: ReaderSettings.key)
        defer { UserDefaults.standard.set(saved, forKey: ReaderSettings.key) }
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        reader.perform(.biggerText)
        reader.perform(.goToEnd)
        await reader.settled()
        let here = try #require(reader.location)
        #expect(here.fraction > 0.9, "The jump was undone, to \(here.fraction)")
    }

    @Test func goToEndAndStartFromTheWindow() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        reader.perform(.goToEnd)
        await reader.settled()
        #expect(reader.location?.isAtEnd == true)
        reader.perform(.goToStart)
        await reader.settled()
        #expect(reader.location?.isAtStart == true)
    }

    @Test func theContentsToggle() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        reader.perform(.toggleTOC)
        await reader.settled()
        #expect(reader.isShowingContents)
        reader.perform(.toggleTOC)
        await reader.settled()
        #expect(!reader.isShowingContents)
    }

    @Test func aBookWithNoContentsHasNoSidebar() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("no-toc.epub"), at: nil)
        reader.perform(.toggleTOC)
        await reader.settled()
        #expect(!reader.isShowingContents)
    }

    @Test func choosingAChapterClosesTheContentsAndGoesThere() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        reader.perform(.toggleTOC)
        await reader.settled()
        let entries = reader.contentsEntries
        let chapter = try #require(entries.first { $0.title == "Chapter 20" })
        reader.choose(chapter)
        await reader.settled()
        #expect(!reader.isShowingContents)
        #expect(reader.location?.chapterTitle == "Chapter 20")
    }

    @Test func theGoToPageFieldGoesToTheTypedPage() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        reader.perform(.goToPage)
        #expect(reader.isShowingPageField)
        let count = try #require(reader.location?.pageCount)
        reader.goToPage(typed: String(count / 2))
        await reader.settled()
        #expect(!reader.isShowingPageField)
        let page = try #require(reader.location?.page)
        #expect(page <= count / 2 && page >= count / 2 - 2)
    }

    @Test func somethingThatIsNotAPageLeavesTheFieldOpen() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        let before = reader.location?.cfi
        reader.perform(.goToPage)
        reader.goToPage(typed: "soon")
        await reader.settled()
        #expect(reader.isShowingPageField)
        #expect(reader.location?.cfi == before)
        reader.closePageField()
        #expect(!reader.isShowingPageField)
    }
}
