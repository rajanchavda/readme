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

/// Runs in a window that is never shown, because Task 4 needs the view to work offscreen,
/// and a page that isn't visible gets no animation frames and throttled timers.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct BookWebViewTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    // MARK: Opening

    @Test func opensBook() async throws {
        let location = try await view.open(fixture("long.epub"), at: nil)
        #expect(location.fraction == 0)
        #expect(location.isAtStart)
        #expect(!location.isAtEnd)
        #expect(location.chapterTitle == "Chapter 1")
        #expect(location.chapterMinutesLeft > 0)
    }

    @Test func notAnEPUBThrows() async throws {
        await #expect(throws: BookWebViewError.self) {
            _ = try await view.open(fixture("not-an-epub.epub"), at: nil)
        }
    }

    @Test func unreadableFileThrows() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nope.epub")
        await #expect(throws: BookWebViewError.unreadable) {
            _ = try await view.open(missing, at: nil)
        }
    }

    @Test func drmBookNeitherCrashesNorHangs() async throws {
        // Task 12 refuses these on import. If one gets here, garbage or an error are both fine.
        let location = try? await view.open(fixture("drm.epub"), at: nil)
        #expect(location == nil || location?.fraction == 0)
    }

    @Test func noCoverOpens() async throws {
        let location = try await view.open(fixture("no-cover.epub"), at: nil)
        #expect(location.isAtStart)
    }

    @Test func opensCopyInContainerWithAwkwardName() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("Moby Dick #1 (é?).epub")
        try FileManager.default.copyItem(at: fixture("no-cover.epub"), to: copy)
        let location = try await view.open(copy, at: nil)
        #expect(location.isAtStart)
    }

    @Test func reopeningReplacesTheBook() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let location = try await view.open(fixture("no-cover.epub"), at: nil)
        #expect(location.isAtStart)
        #expect(await view.toc().count == 3)
    }

    // MARK: Moving

    @Test func nextAdvances() async throws {
        let first = try await view.open(fixture("long.epub"), at: nil)
        let second = try #require(await view.next())
        #expect(second.fraction > first.fraction)
        #expect(second.cfi != first.cfi)
        #expect(!second.isAtStart)
    }

    @Test func previousReturnsAndStopsAtStart() async throws {
        let first = try await view.open(fixture("long.epub"), at: nil)
        #expect(await view.previous() == nil)
        _ = try #require(await view.next())
        let back = try #require(await view.previous())
        #expect(back.cfi == first.cfi)
        #expect(back.isAtStart)
    }

    @Test func crossingAChapterGoesBothWays() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        var last: ReaderLocation?
        for _ in 0..<40 {
            guard let location = await view.next() else { break }
            last = location
            if location.chapterTitle == "Chapter 2" { break }
        }
        let start = try #require(last)
        #expect(start.chapterTitle == "Chapter 2")
        let end = try #require(await view.previous())
        #expect(end.chapterTitle == "Chapter 1")
        #expect(end.fraction < start.fraction)
    }

    @Test func nextStopsAtTheEnd() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        var last: ReaderLocation?
        for _ in 0..<100 {
            guard let location = await view.next() else { break }
            last = location
        }
        #expect(try #require(last).isAtEnd)
        #expect(await view.next() == nil)
    }

    @Test func turnsFiredFasterThanFoliateAcceptsAreNotDropped() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        // Foliate ignores a turn for 100 ms after the previous one.
        let turns = (0..<4).map { _ in Task { await view.next() } }
        var results: [ReaderLocation?] = []
        for turn in turns { results.append(await turn.value) }
        let fractions = results.compactMap { $0?.fraction }
        #expect(fractions.count == 4)
        #expect(fractions == fractions.sorted())
        #expect(Set(fractions).count == 4)
    }

    @Test func chapterMinutesLeftFalls() async throws {
        let first = try await view.open(fixture("long.epub"), at: nil)
        let second = try #require(await view.next())
        #expect(second.chapterTitle == first.chapterTitle)
        #expect(second.chapterMinutesLeft < first.chapterMinutesLeft)
        #expect(second.chapterMinutesLeft > 0)
    }

    @Test func onRelocateReportsEachTurnOnce() async throws {
        var seen: [String] = []
        view.onRelocate = { seen.append($0.cfi) }
        let first = try await view.open(fixture("long.epub"), at: nil)
        let second = try #require(await view.next())
        try await settleMessages()
        #expect(seen == [first.cfi, second.cfi])
        #expect(view.currentLocation == second)
    }

    @Test func movingAcrossChaptersHidesTheInBetweenStops() async throws {
        var seen: [ReaderLocation] = []
        let location = try await view.open(fixture("long.epub"), at: nil)
        view.onRelocate = { seen.append($0) }
        let far = try #require(await view.go(toFraction: 0.5))
        try await settleMessages()
        #expect(far.cfi != location.cfi)
        #expect(seen == [far])
    }

    // MARK: Position

    @Test func returnsToSavedPlace() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let saved = try #require(await view.go(toFraction: 0.5))
        #expect(abs(saved.fraction - 0.5) < 0.02)
        let reopened = try await view.open(fixture("long.epub"), at: saved.cfi)
        #expect(reopened.cfi == saved.cfi)
    }

    @Test func goToCFIReturnsThere() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let saved = try #require(await view.go(toFraction: 0.7))
        _ = try #require(await view.go(toFraction: 0.1))
        let back = try #require(await view.go(toCFI: saved.cfi))
        #expect(back.cfi == saved.cfi)
    }

    @Test func staleCFIStartsAtTheBeginning() async throws {
        let location = try await view.open(fixture("no-cover.epub"), at: "epubcfi(/6/999!/4/2/1:0)")
        #expect(location.isAtStart)
        let garbage = try await view.open(fixture("no-cover.epub"), at: "not a cfi")
        #expect(garbage.isAtStart)
    }

    @Test func badGoToCFIStaysPut() async throws {
        let start = try await view.open(fixture("no-cover.epub"), at: nil)
        #expect(await view.go(toCFI: "epubcfi(/6/999!/4/2/1:0)") == nil)
        #expect(view.currentLocation == start)
    }

    @Test func goToFractionClampsOutOfRangeValues() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        #expect(try #require(await view.go(toFraction: 2)).isAtEnd)
        #expect(try #require(await view.go(toFraction: -1)).isAtStart)
        #expect(await view.go(toFraction: .nan) == nil)
    }

    // MARK: Messy books

    @Test func bookScriptsNeverRun() async throws {
        _ = try await view.open(fixture("scripted.epub"), at: nil)
        try await Task.sleep(for: .milliseconds(500))
        // The chapter did load, with its scripts still in it, or this test would prove nothing.
        let chapterTitle = try await view.call(
            "return readmeBridge.currentDocument().title", as: String.self)
        #expect(chapterTitle == "Scripted Chapter")
        let scriptCount = try await view.call(
            "return readmeBridge.currentDocument().querySelectorAll('script').length", as: Int.self)
        #expect(scriptCount == 2)

        #expect(view.webView.title == "Readme")
        #expect(view.rejectedMessageCount == 0)
        let pwned = try await view.call("return window.__pwned === true", as: Bool.self)
        #expect(pwned == false)
    }

    /// The CSP allows images from anywhere, so the rule list is what keeps a book from calling
    /// out. This only proves anything when online, as the image also fails when offline.
    @Test func remoteImageInABookIsNotLoaded() async throws {
        _ = try await view.open(fixture("remote-image.epub"), at: nil)
        let state = try await view.call(
            """
            const image = readmeBridge.currentDocument().getElementById('remote')
            if (!image) return 'no image'
            if (!image.src.startsWith('https://')) return 'src was rewritten: ' + image.src
            for (let i = 0; i < 100 && !image.complete; i++)
                await new Promise(resolve => setTimeout(resolve, 100))
            return image.complete && image.naturalWidth === 0 ? 'blocked' : 'loaded'
            """,
            as: String.self)
        #expect(state == "blocked")
    }

    @Test func openThrowsIfTheRemoteBlockFailsToCompile() async throws {
        view.remoteBlockRules = "not valid rules"
        await #expect(throws: BookWebViewError.self) {
            _ = try await view.open(fixture("no-cover.epub"), at: nil)
        }
        // Nothing was loaded unprotected: the reader page was never even requested.
        #expect(view.webView.url == nil)
        #expect(await view.next() == nil)

        // Fixing the rules lets the same view open a book, and the block is then in place.
        view.remoteBlockRules = BookWebView.defaultRemoteBlockRules
        _ = try await view.open(fixture("remote-image.epub"), at: nil)
        #expect(view.currentLocation != nil)
    }

    @Test func brokenChapterStillOpens() async throws {
        let first = try await view.open(fixture("broken-chapter.epub"), at: nil)
        #expect(first.chapterTitle == "Good Start")
        var last = first
        var titles = [first.chapterTitle]
        for _ in 0..<100 {
            guard let location = await view.next() else { break }
            #expect(location.fraction >= last.fraction)
            last = location
            titles.append(location.chapterTitle)
        }
        #expect(last.isAtEnd)
        #expect(last.chapterTitle == "Good End")
        #expect(titles.contains("Malformed"))
    }

    @Test func brokenChapterCanBeJumpedToAndLeft() async throws {
        _ = try await view.open(fixture("broken-chapter.epub"), at: nil)
        let toc = await view.toc()
        for entry in toc {
            _ = await view.go(toFraction: entry.fraction)
            #expect(view.currentLocation != nil)
        }
        #expect(try #require(await view.go(toFraction: 0)).isAtStart)
        #expect(await view.next() != nil)
    }

    @Test func hungJavaScriptTimesOut() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        await #expect(throws: BookWebViewError.timedOut) {
            // Kept reachable, or WebKit notices nothing can ever answer and reports an error itself.
            _ = try await view.call(
                "globalThis.hung = {}; await new Promise(resolve => { globalThis.hung.resolve = resolve })",
                as: Bool.self, timeout: .milliseconds(200))
        }
    }

    @Test func javaScriptErrorsThrow() async throws {
        _ = try await view.open(fixture("no-cover.epub"), at: nil)
        await #expect(throws: BookWebViewError.self) {
            _ = try await view.call("throw new Error('boom')", as: Bool.self)
        }
        // A reply of undefined must not trip WebKit's "neither result nor failure" trap.
        #expect(try await view.call("return undefined", as: Bool.self) == nil)
    }

    @Test func callsBeforeOpeningAreHarmless() async {
        #expect(await view.next() == nil)
        #expect(await view.previous() == nil)
        #expect(await view.go(toFraction: 0.5) == nil)
        #expect(await view.go(toCFI: "epubcfi(/6/2!)") == nil)
        #expect(await view.toc() == [])
        await view.applyStyles(css: "", columns: 2)
    }

    // MARK: Table of contents

    @Test func missingTOCIsEmpty() async throws {
        _ = try await view.open(fixture("no-toc.epub"), at: nil)
        #expect(await view.toc() == [])
    }

    @Test func tocHasLevelsAndPlaces() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let toc = await view.toc()
        #expect(toc.count == 41)
        #expect(toc[0].title == "Chapter 1")
        #expect(toc[0].level == 0)
        #expect(toc[0].fraction == 0)
        let fractions = toc.map(\.fraction)
        #expect(fractions == fractions.sorted())

        let part = try #require(toc.first { $0.title == "Chapter 5, Part Two" })
        let chapter = try #require(toc.first { $0.title == "Chapter 5" })
        let nextChapter = try #require(toc.first { $0.title == "Chapter 6" })
        #expect(part.level == 1)
        #expect(part.href.hasSuffix("#part-two"))
        #expect(part.fraction > chapter.fraction)
        #expect(part.fraction < nextChapter.fraction)

        let landed = try #require(await view.go(toFraction: toc[20].fraction))
        #expect(landed.chapterTitle == toc[20].title)
    }

    // MARK: Styles and layout

    private func columnWidth() async throws -> Double {
        let width = try await view.call(
            "return parseFloat(readmeBridge.currentDocument().documentElement.style.columnWidth)",
            as: Double.self)
        return try #require(width)
    }

    @Test func columnsDriveTheLayout() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let two = try await columnWidth()
        await view.applyStyles(css: "", columns: 1)
        let one = try await columnWidth()
        #expect(one > two * 1.3)
        await view.applyStyles(css: "", columns: 2)
        #expect(try await columnWidth() == two)
    }

    @Test func twoColumnsHoldInANarrowView() async throws {
        window.setContentSize(NSSize(width: 640, height: 500))
        _ = try await view.open(fixture("long.epub"), at: nil)
        await view.applyStyles(css: "", columns: 2)
        #expect(try await columnWidth() < 300)
    }

    @Test func stylesAndColumnsSurviveReopening() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        await view.applyStyles(css: "body { color: rgb(1, 2, 3) }", columns: 1)
        let one = try await columnWidth()
        _ = try await view.open(fixture("long.epub"), at: nil)
        #expect(try await columnWidth() == one)
        let color = try await view.call(
            "const doc = readmeBridge.currentDocument(); return doc.defaultView.getComputedStyle(doc.body).color",
            as: String.self)
        #expect(color == "rgb(1, 2, 3)")
    }

    @Test func applyStylesHoldsThePlaceAndReportsOnce() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let before = try #require(await view.go(toFraction: 0.5))
        var seen: [ReaderLocation] = []
        view.onRelocate = { seen.append($0) }

        await view.applyStyles(css: "body { font-size: 200% !important }", columns: 1)

        // applyStyles has re-settled by the time it returns.
        let after = try #require(view.currentLocation)
        #expect(after.chapterTitle == before.chapterTitle)
        #expect(abs(after.fraction - before.fraction) < 0.01)
        #expect(after.cfi != before.cfi)
        try await settleMessages()
        #expect(seen == [after])

        // The first words that were on the spread are still on the spread.
        let onSpread = try await view.call(
            """
            const foliate = document.querySelector('foliate-view')
            const { renderer } = foliate
            const range = foliate.resolveCFI(cfi).anchor(readmeBridge.currentDocument())
            range.collapse(true)
            const text = range.startContainer.nodeType === 3
            const start = range.startContainer.parentElement ?? range.startContainer
            const rects = (text ? range : start).getClientRects()
            const left = (rects[0] ?? start.getBoundingClientRect()).left
            return left >= renderer.start - renderer.size && left < renderer.end - renderer.size
            """,
            arguments: ["cfi": before.cfi],
            as: Bool.self)
        #expect(onSpread == true)
    }

    // MARK: Offscreen use

    @Test func snapshotFromHiddenWindowHasInk() async throws {
        _ = try await view.open(fixture("long.epub"), at: nil)
        let image = try await snapshot()
        #expect(image.width >= 1000)
        #expect(darkFraction(image) > 0.005)
    }

    // MARK: Scheme and policy

    @Test func contentSecurityPolicyIsExact() {
        #expect(BookScheme.contentSecurityPolicy == "default-src 'self' blob: readme-book:; script-src 'self'; connect-src 'self' blob: readme-book:; img-src * blob: data: readme-book:; style-src * 'unsafe-inline'; font-src * blob: data: readme-book:")
    }

    @Test func schemeStaysInsideItsRoot() {
        let root = URL(fileURLWithPath: "/Applications/Readme.app/Contents/Resources/Web")
        #expect(BookScheme.resourceURL(forPath: "/reader.html", in: root)?.lastPathComponent == "reader.html")
        #expect(BookScheme.resourceURL(forPath: "/foliate/vendor/zip.js", in: root)?.path.hasSuffix("/Web/foliate/vendor/zip.js") == true)
        #expect(BookScheme.resourceURL(forPath: "/../../Info.plist", in: root) == nil)
        #expect(BookScheme.resourceURL(forPath: "/foliate/../../secret", in: root) == nil)
        #expect(BookScheme.resourceURL(forPath: "/", in: root) == nil)
    }

    @Test func navigationIsLimitedToTheReader() {
        let reader = BookScheme.readerURL
        #expect(BookWebView.allowsNavigation(to: reader, inMainFrame: true))
        #expect(!BookWebView.allowsNavigation(to: URL(string: "https://example.com")!, inMainFrame: true))
        #expect(!BookWebView.allowsNavigation(to: URL(string: "blob:readme-book://app/x")!, inMainFrame: true))
        #expect(BookWebView.allowsNavigation(to: URL(string: "blob:readme-book://app/x")!, inMainFrame: false))
        #expect(BookWebView.allowsNavigation(to: URL(string: "about:blank")!, inMainFrame: false))
        #expect(!BookWebView.allowsNavigation(to: URL(string: "https://example.com")!, inMainFrame: false))
        #expect(!BookWebView.allowsNavigation(to: URL(string: "file:///etc/passwd")!, inMainFrame: false))
    }

    // MARK: Helpers

    /// Lets relocate messages that are already on their way arrive.
    private func settleMessages() async throws {
        try await Task.sleep(for: .milliseconds(400))
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
