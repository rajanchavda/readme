import AppKit
import Foundation

struct ThemeColors {
    var page, ink, soft, desk, spine: NSColor
}

/// The style sheet laid over a book: theme colours, font, size and spacing. Rules that must beat
/// the book's own are `!important`; italics, headings' sizes and images are left alone.
enum ReadingCSS {
    /// Fullscreen text is a third larger.
    static let fullscreenScale = 4.0 / 3.0

    static func colors(_ theme: Theme) -> ThemeColors {
        switch theme {
        case .paper:
            ThemeColors(page: rgb(0xF8F5EE), ink: rgb(0x2B261F), soft: rgb(0x8A7C66),
                        desk: rgb(0x3A332C), spine: rgba(70, 50, 25, 0.32))
        case .sepia:
            ThemeColors(page: rgb(0xEFE0C4), ink: rgb(0x33291B), soft: rgb(0x8D7650),
                        desk: rgb(0x4A3A28), spine: rgba(80, 50, 15, 0.36))
        case .night:
            ThemeColors(page: rgb(0x26272A), ink: rgb(0xBDB9AF), soft: rgb(0x6F6D66),
                        desk: rgb(0x17181A), spine: rgba(0, 0, 0, 0.45))
        }
    }

    static func css(_ settings: ReaderSettings, theme: Theme, fullscreen: Bool) -> String {
        let colors = colors(theme)
        let page = hex(colors.page), ink = hex(colors.ink)
        let size = settings.fontSize * (fullscreen ? fullscreenScale : 1)
        let family = family(settings.font)
        let text = "p, li, blockquote, dd, dt, td, th, div, span, a, em, i, b, strong, cite, q, small, h1, h2, h3, h4, h5, h6"
        return """
        \(fontFaces)
        html, body {
            background: \(page) !important;
            color: \(ink) !important;
        }
        body {
            font-family: \(family) !important;
            font-size: \(number(size))px !important;
            line-height: 1.55 !important;
            hyphens: auto;
            -webkit-hyphens: auto;
        }
        body :is(\(text)) {
            font-family: inherit !important;
            line-height: 1.55 !important;
            color: \(ink) !important;
        }
        body :is(p, li, blockquote, dd) {
            text-align: justify;
        }
        ::selection { background: \(hex(colors.soft))66; }
        """
    }

    // MARK: Fonts

    private static func family(_ font: BookFont) -> String {
        switch font {
        case .ebGaramond: "\"EB Garamond\", Georgia, serif"
        case .literata: "\"Literata\", Georgia, serif"
        case .newYork: "ui-serif, \"New York\", Georgia, serif"
        }
    }

    /// The bundled fonts, served through the book scheme. Both are variable, so one file covers
    /// every weight.
    private static var fontFaces: String {
        let faces: [(family: String, file: String, style: String, weights: String)] = [
            ("EB Garamond", "EBGaramond.ttf", "normal", "400 800"),
            ("EB Garamond", "EBGaramond-Italic.ttf", "italic", "400 800"),
            ("Literata", "Literata.ttf", "normal", "200 900"),
            ("Literata", "Literata-Italic.ttf", "italic", "200 900"),
        ]
        return faces.map {
            """
            @font-face { font-family: "\($0.family)"; src: url("\(BookScheme.scheme)://app/fonts/\($0.file)"); \
            font-style: \($0.style); font-weight: \($0.weights); font-display: block; }
            """
        }.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func number(_ value: Double) -> String { String(format: "%g", value) }

    private static func rgb(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}
