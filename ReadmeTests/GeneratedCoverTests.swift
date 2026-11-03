import AppKit
import CryptoKit
import SwiftUI
import Testing
@testable import Readme

private func book(
    _ id: String, title: String = "A Title", author: String? = "An Author", hasCover: Bool = false
) -> Book {
    Book(
        id: id, title: title, author: author, fileName: "\(id).epub", hasCover: hasCover,
        addedAt: Date(timeIntervalSince1970: 0), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

/// WCAG relative luminance.
private func luminance(_ color: Color) -> Double {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    func channel(_ v: CGFloat) -> Double {
        let v = Double(v)
        return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
}

private func contrast(_ a: Color, _ b: Color) -> Double {
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

@MainActor
@Suite struct GeneratedCoverTests {
    @Test func stable() {
        // A fixed ID gives a fixed palette, so it is the same on every launch.
        let id = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        #expect(GeneratedCover.palette(for: book(id)) == GeneratedCover.palette(for: book(id)))
        #expect(GeneratedCover.palettes.firstIndex(of: GeneratedCover.palette(for: book(id))) == 7)
    }

    @Test func spread() {
        let used = Set((0..<20).map { i in
            GeneratedCover.palettes.firstIndex(of: GeneratedCover.palette(for: book(sampleID(i)))) ?? -1
        })
        #expect(used.count >= 5)
        #expect(!used.contains(-1))
    }

    @Test func twelvePalettes() {
        #expect(GeneratedCover.palettes.count == 12)
        #expect(Set(GeneratedCover.palettes.map { "\($0.background)\($0.ink)" }).count == 12)
    }

    @Test func readable() {
        for palette in GeneratedCover.palettes {
            #expect(contrast(palette.ink, palette.background) >= 4.5)
        }
    }

    @Test func missingAuthorIsFine() throws {
        let image = render(BookCoverView(book: book("a", author: nil), width: 150, library: try emptyLibrary()))
        #expect(image != nil)
    }
}

@MainActor
@Suite struct CoverFontTests {
    @Test func bundledFontsAreFound() {
        BundledFonts.register()
        #expect(NSFont(name: "Fraunces", size: 20) != nil)
        #expect(NSFont(name: "EBGaramond-Italic", size: 20) != nil)
        #expect(NSFont(name: "EB Garamond Italic", size: 20) != nil)
        #expect(CoverFonts.title(size: 20).familyName == "Fraunces")
        #expect(CoverFonts.title(size: 20).fontName == "Fraunces-SemiBold")
        #expect(CoverFonts.author(size: 20).fontName == "EBGaramond-Italic")
    }

    @Test func registeringTwiceIsHarmless() {
        BundledFonts.register()
        BundledFonts.register()
        #expect(NSFont(name: "Fraunces", size: 20) != nil)
    }
}

@MainActor
@Suite struct CoverLayoutTests {
    private let width: CGFloat = 150

    private func check(_ title: String, _ author: String?, sourceLocation: SourceLocation = #_sourceLocation) {
        BundledFonts.register()
        let layout = GeneratedCover.layout(title: title, author: author, width: width)
        let inner = width * 0.82
        let parts: [(GeneratedCover.Lines?, (CGFloat) -> NSFont)] = [
            (layout.title, { CoverFonts.title(size: $0) }), (layout.author, { CoverFonts.author(size: $0) }),
        ]
        for (text, font) in parts {
            guard let text else { continue }
            for line in text.lines {
                let w = (line as NSString).size(withAttributes: [.font: font(text.size)]).width
                #expect(w <= inner + 0.5, "\(line) is \(w) wide", sourceLocation: sourceLocation)
            }
        }
        let used = (CGFloat(layout.title.lines.count) * layout.title.size * GeneratedCover.lineHeight)
            + (layout.author.map { CGFloat($0.lines.count) * $0.size * GeneratedCover.lineHeight } ?? 0)
        #expect(used <= width * 1.5 - width * 0.18, sourceLocation: sourceLocation)
    }

    @Test func shortTitleKeepsFullSize() {
        BundledFonts.register()
        let layout = GeneratedCover.layout(title: "Walden", author: "Henry David Thoreau", width: width)
        #expect(layout.title.size == width * 0.135)
        #expect(layout.title.lines == ["Walden"])
    }

    @Test func longTitleShrinksAndWrapsOnWords() {
        let title = "The Extraordinary and Surprising Adventures of a Rather Long-Winded Gentleman"
        check(title, "A Very Prolific and Widely Travelled Author of Many Books")
        let layout = GeneratedCover.layout(title: title, author: nil, width: width)
        #expect(layout.title.size < width * 0.135)
        #expect(layout.title.lines.joined(separator: " ") == title)
    }

    @Test func longSingleWordIsNeverCut() {
        let word = "Internationalization"
        check(word, "Someone")
        let layout = GeneratedCover.layout(title: word, author: nil, width: width)
        #expect(layout.title.lines == [word])
    }

    @Test func absurdWordIsBrokenNotClipped() {
        let word = String(repeating: "Supercali", count: 20)
        check(word, "Someone")
        #expect(GeneratedCover.layout(title: word, author: nil, width: width).title.lines.joined() .hasPrefix("Supercali"))
    }

    @Test func absurdlyLongTitleEndsInEllipsis() {
        let title = Array(repeating: "words", count: 300).joined(separator: " ")
        check(title, "Someone")
        let lines = GeneratedCover.layout(title: title, author: nil, width: width).title.lines
        #expect(lines.last?.hasSuffix("…") == true)
    }

    @Test func emptyTitleAndAuthorOnly() {
        check("", "Only An Author")
        check("   ", nil)
        #expect(!GeneratedCover.layout(title: "", author: nil, width: width).title.lines.isEmpty)
    }

    @Test func nonLatinScripts() {
        check("吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。", "夏目漱石")
        check("Война и мир", "Лев Толстой")
        check("مئة عام من العزلة", "غابرييل غارسيا ماركيز")
        check("शेखर: एक जीवनी", "अज्ञेय")
        check("📚🙂 Emoji 👨‍👩‍👧‍👦 Title", "🙂")
    }

    @Test func lastLineIsNotAnOrphan() {
        BundledFonts.register()
        let lines = GeneratedCover.layout(title: "吾輩は猫である", author: nil, width: width).title.lines
        #expect(lines.count == 2)
        #expect(lines.map(\.count).min()! >= 3)
        let latin = GeneratedCover.layout(title: "The Count of Monte Cristo", author: nil, width: width).title
        let widths = latin.lines.map { ($0 as NSString).size(withAttributes: [.font: CoverFonts.title(size: latin.size)]).width }
        #expect(latin.lines.count < 2 || widths.min()! > widths.max()! * 0.4)
    }

    @Test func smallAndLargeWidths() {
        for w: CGFloat in [60, 112, 150, 300] {
            let layout = GeneratedCover.layout(title: "Great Expectations and Other Long Things", author: "Charles Dickens", width: w)
            #expect(!layout.title.lines.isEmpty)
        }
    }
}

// MARK: Rendering

@MainActor
func emptyLibrary() throws -> LibraryStore {
    LibraryStore(directory: try libraryFolder())
}

@MainActor
func render(_ view: some View, scale: CGFloat = 2) -> NSImage? {
    let renderer = ImageRenderer(content: view.padding(20).background(Color(white: 0.2)))
    renderer.scale = scale
    return renderer.nsImage
}

@MainActor
@Suite struct BookCoverViewTests {
    private func png(_ color: NSColor, size: NSSize, to url: URL) throws {
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 10).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func realCoverIsDecodedOffMainAndCached() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("wide.png")
        try png(.red, size: NSSize(width: 400, height: 200), to: url)

        #expect(CoverImages.cached(url, width: 150) == nil)
        let image = await CoverImages.load(url, width: 150)
        let loaded = try #require(image)
        #expect(loaded.width > 0)
        #expect(CoverImages.cached(url, width: 150) != nil)
    }

    @Test func missingOrBrokenCoverLoadsNothing() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await CoverImages.load(folder.appendingPathComponent("nope.png"), width: 150) == nil)
        let junk = folder.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        #expect(await CoverImages.load(junk, width: 150) == nil)
    }

    @Test func fillCropsToTwoByThree() throws {
        let size = CoverImages.fillRect(imageSize: CGSize(width: 400, height: 200), in: CGSize(width: 100, height: 150))
        #expect(size.height == 150)
        #expect(size.width == 300)
        let tall = CoverImages.fillRect(imageSize: CGSize(width: 100, height: 400), in: CGSize(width: 100, height: 150))
        #expect(tall.width == 100)
        #expect(tall.height == 400)
    }

    private func key(_ book: Book, _ width: CGFloat = 150) -> BookCoverView.Key {
        BookCoverView.Key(id: book.id, hasCover: book.hasCover, width: width)
    }

    @Test func staleStateOfAnotherBookIsNotShown() throws {
        let image = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let a = book("aa", hasCover: true), b = book("bb", hasCover: true)
        let resolved = BookCoverView.Resolved(key: key(a), state: .loaded(image))
        if case .loaded = BookCoverView.shown(resolved, for: key(a), initial: .loading) {} else { Issue.record("own state not shown") }
        if case .loading = BookCoverView.shown(resolved, for: key(b), initial: .loading) {} else {
            Issue.record("another book's cover was shown")
        }
        // A new width is a new key too.
        if case .loading = BookCoverView.shown(resolved, for: key(a, 200), initial: .loading) {} else {
            Issue.record("another size's state was shown")
        }
    }

    @Test func aCancelledLoadLeavesNoTrace() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("big.png")
        try png(.blue, size: NSSize(width: 1200, height: 1800), to: url)
        // Starts on the main actor, so it can't run until this test waits: it is cancelled before it begins.
        let task = Task { await CoverImages.load(url, width: 150) }
        task.cancel()
        #expect(await task.value == nil)
        #expect(CoverImages.cached(url, width: 150) == nil)
        #expect(!CoverImages.knownUnreadable(url))
    }

    @Test func cacheIsBoundedByBytes() {
        #expect(CoverImages.byteLimit == 64 * 1024 * 1024)
    }

    @Test func aBrokenCoverFileShowsTheGeneratedCover() async throws {
        let library = try emptyLibrary()
        defer { try? FileManager.default.removeItem(at: library.coversDirectory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: library.coversDirectory, withIntermediateDirectories: true)
        let broken = book("0badc0de", hasCover: true)
        try Data("x".utf8).write(to: library.coverURL(for: broken))
        let missing = book("0ff1ce", hasCover: true)
        let real = book("c0ffee", hasCover: true)
        try png(.systemTeal, size: NSSize(width: 500, height: 300), to: library.coverURL(for: real))

        if case .failed = await BookCoverView.resolve(broken, in: library, width: 150) {} else { Issue.record("broken") }
        if case .failed = await BookCoverView.resolve(missing, in: library, width: 150) {} else { Issue.record("missing") }
        if case .loaded(let image) = await BookCoverView.resolve(real, in: library, width: 150) {
            #expect(image.width > 0)
        } else {
            Issue.record("real")
        }
        if case .failed = await BookCoverView.resolve(book("n0cover"), in: library, width: 150) {} else { Issue.record("none") }
    }

    /// Renders the covers for looking at, when `COVER_RENDERS` is set (`TEST_RUNNER_COVER_RENDERS=1 scripts/test.sh`).
    @Test func rendersSavedForLooking() async throws {
        BundledFonts.register()
        let library = try emptyLibrary()
        defer { try? FileManager.default.removeItem(at: library.coversDirectory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: library.coversDirectory, withIntermediateDirectories: true)
        let withCover = book("c0ffee", title: "Real", hasCover: true)
        try png(.systemTeal, size: NSSize(width: 500, height: 300), to: library.coverURL(for: withCover))
        let broken = book("deadbeef", title: "Broken Cover Falls Back", author: "Nobody", hasCover: true)
        try Data("x".utf8).write(to: library.coverURL(for: broken))

        let samples: [(String, Book)] = [
            ("short", book(sampleID(1), title: "Walden", author: "Henry David Thoreau")),
            ("long", book(sampleID(2), title: "The Extraordinary and Surprising Adventures of a Rather Long-Winded Gentleman", author: "A Very Prolific and Widely Travelled Author")),
            ("longword", book(sampleID(3), title: "Internationalization", author: "Someone")),
            ("noauthor", book(sampleID(4), title: "Frankenstein", author: nil)),
            ("empty", book(sampleID(5), title: "", author: "Only An Author")),
            ("japanese", book(sampleID(6), title: "吾輩は猫である", author: "夏目漱石")),
            ("broken", broken),
            ("real", withCover),
        ]
        // Loads first, as the view does, so the render shows what the shelf would.
        _ = await CoverImages.load(library.coverURL(for: withCover), width: 150)
        _ = await CoverImages.load(library.coverURL(for: broken), width: 150)
        let dump = ProcessInfo.processInfo.environment["COVER_RENDERS"] != nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("task13-renders", isDirectory: true)
        if dump { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, book) in samples {
            let image = try #require(render(BookCoverView(book: book, width: 150, library: library)))
            // 150 by 225, and 20 of padding round it, at 2x.
            #expect(image.representations.first?.pixelsWide == 380, "\(name)")
            #expect(image.representations.first?.pixelsHigh == 530, "\(name)")
            if dump {
                try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
                    .write(to: dir.appendingPathComponent("\(name).png"))
            }
        }
    }
}

/// An ID like a real one: the SHA-256 of something that differs per book.
private func sampleID(_ i: Int) -> String {
    SHA256.hash(data: Data("book \(i)".utf8)).map { String(format: "%02x", $0) }.joined()
}
