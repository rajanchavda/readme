import AppKit
import Foundation
import Testing
import WebKit
@testable import Readme

private func hex(_ color: NSColor) -> String {
    let c = color.usingColorSpace(.sRGB)!
    func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
}

private func defaults() -> UserDefaults {
    let name = "ReaderSettingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite struct ReaderSettingsTests {
    @Test func defaultSettings() {
        let settings = ReaderSettings()
        #expect(settings.font == .ebGaramond)
        #expect(settings.theme == .auto)
        #expect(settings.fontSize == 18)
        #expect(settings.lineWidth == .regular)
    }

    @Test func autoFollowsSystem() {
        let settings = ReaderSettings()
        #expect(settings.resolvedTheme(systemIsDark: true) == .night)
        #expect(settings.resolvedTheme(systemIsDark: false) == .paper)
    }

    @Test func explicitThemeWins() {
        var settings = ReaderSettings()
        settings.theme = .sepia
        #expect(settings.resolvedTheme(systemIsDark: true) == .sepia)
        #expect(settings.resolvedTheme(systemIsDark: false) == .sepia)
    }

    @Test func savesAndLoads() {
        let store = defaults()
        var settings = ReaderSettings()
        settings.theme = .night
        settings.font = .literata
        settings.fontSize = 21
        settings.lineWidth = .wide
        settings.save(store)
        #expect(ReaderSettings.load(store) == settings)
    }

    @Test func loadsDefaultsWhenNothingSavedOrUnreadable() {
        let store = defaults()
        #expect(ReaderSettings.load(store) == ReaderSettings())
        store.set(Data("not json".utf8), forKey: ReaderSettings.key)
        #expect(ReaderSettings.load(store) == ReaderSettings())
    }

    @Test func cssValues() {
        let settings = ReaderSettings()
        let css = ReadingCSS.css(settings, theme: .paper, fullscreen: false)
        #expect(css.contains("line-height: 1.55"))
        #expect(css.contains("hyphens: auto"))
        #expect(css.contains("text-align: justify"))
        #expect(css.contains("#F8F5EE"))
        #expect(hex(ReadingCSS.colors(.paper).page) == "#F8F5EE")
        #expect(hex(ReadingCSS.colors(.sepia).page) == "#EFE0C4")
        #expect(hex(ReadingCSS.colors(.night).page) == "#26272A")
        #expect(hex(ReadingCSS.colors(.night).ink) == "#BDB9AF")
        #expect(hex(ReadingCSS.colors(.paper).desk) == "#3A332C")
        #expect(hex(ReadingCSS.colors(.sepia).desk) == "#4A3A28")
        #expect(hex(ReadingCSS.colors(.night).desk) == "#17181A")
        #expect(ReadingCSS.css(settings, theme: .sepia, fullscreen: false).contains("#EFE0C4"))
        let night = ReadingCSS.css(settings, theme: .night, fullscreen: false)
        #expect(night.contains("#26272A") && night.contains("#BDB9AF"))
    }

    @Test func fontFamilies() {
        var settings = ReaderSettings()
        #expect(ReadingCSS.css(settings, theme: .paper, fullscreen: false).contains("\"EB Garamond\""))
        settings.font = .literata
        #expect(ReadingCSS.css(settings, theme: .paper, fullscreen: false).contains("\"Literata\""))
        settings.font = .newYork
        #expect(ReadingCSS.css(settings, theme: .paper, fullscreen: false).contains("ui-serif"))
    }

    @Test func fullscreenTextIsLarger() {
        let settings = ReaderSettings()
        #expect(ReadingCSS.css(settings, theme: .paper, fullscreen: false).contains("font-size: 18px"))
        #expect(ReadingCSS.css(settings, theme: .paper, fullscreen: true).contains("font-size: 24px"))
    }

    @Test func bookStylesLoseForBodyTextButItalicsAndImagesSurvive() {
        let css = ReadingCSS.css(ReaderSettings(), theme: .paper, fullscreen: false)
        // The reader's rules are !important so a book's own can't beat them.
        #expect(css.contains("color: #2B261F !important"))
        #expect(css.contains("line-height: 1.55 !important"))
        // Nothing here resets italics or image sizes.
        #expect(!css.contains("font-style: normal !important") && !css.contains("font-style: inherit"))
        #expect(!css.contains("img {"))
    }

    // MARK: Layout

    @Test func twoPagesWhenWide() {
        #expect(SpreadLayout.columns(windowWidth: 1200, fontSize: 18, lineWidth: .regular) == 2)
    }

    @Test func onePageWhenNarrow() {
        #expect(SpreadLayout.columns(windowWidth: 700, fontSize: 18, lineWidth: .regular) == 1)
    }

    @Test func largeTextDropsToOnePage() {
        #expect(SpreadLayout.columns(windowWidth: 1000, fontSize: 32, lineWidth: .regular) == 1)
    }

    @Test func portraitAreaIsOnePageHoweverWide() {
        #expect(SpreadLayout.columns(windowWidth: 1200, fontSize: 18, lineWidth: .regular, windowHeight: 1300) == 1)
        #expect(SpreadLayout.columns(windowWidth: 1200, fontSize: 18, lineWidth: .regular, windowHeight: 800) == 2)
    }
}

private final class FixtureToken {}

/// Fonts must render in the real web view, not merely sit in the bundle.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct BundledFontTests {
    let window: NSWindow
    let view: BookWebView

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = BookWebView(frame: frame)
        window.contentView = view
    }

    private func loadedFaces(_ font: BookFont, italic: Bool = false) async throws -> [String] {
        let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
        _ = try await view.open(root.appendingPathComponent("long.epub"), at: nil)
        var settings = ReaderSettings()
        settings.font = font
        await view.applyStyles(css: ReadingCSS.css(settings, theme: .paper, fullscreen: false), columns: 1)
        let style = italic ? "italic " : ""
        return try #require(try await view.call(
            """
            const doc = readmeBridge.currentDocument()
            const faces = await doc.fonts.load('\(style)18px "\(font == .literata ? "Literata" : "EB Garamond")"')
            return faces.filter(face => face.status === 'loaded').map(face => face.family + ' ' + face.style)
            """, as: [String].self))
    }

    @Test func ebGaramondRenders() async throws {
        #expect(try await loadedFaces(.ebGaramond).count == 1)
    }

    @Test func ebGaramondItalicRenders() async throws {
        #expect(try await loadedFaces(.ebGaramond, italic: true).count == 1)
    }

    @Test func literataRenders() async throws {
        #expect(try await loadedFaces(.literata).count == 1)
    }

    @Test func readingColoursBeatTheBooksOwn() async throws {
        let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
        _ = try await view.open(root.appendingPathComponent("long.epub"), at: nil)
        await view.applyStyles(css: ReadingCSS.css(ReaderSettings(), theme: .night, fullscreen: false), columns: 1)
        let colour = try await view.call(
            "const doc = readmeBridge.currentDocument(); return doc.defaultView.getComputedStyle(doc.querySelector('p') ?? doc.body).color",
            as: String.self)
        #expect(colour == "rgb(189, 185, 175)")
    }
}
