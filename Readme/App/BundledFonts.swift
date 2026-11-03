import AppKit
import CoreText

/// The fonts the app ships in `Web/fonts`, made known to AppKit and SwiftUI. The reading web view
/// has its own `@font-face`, which SwiftUI can't use.
enum BundledFonts {
    private static let registered: Void = {
        let folder = Bundle(for: BundleToken.self).resourceURL?
            .appendingPathComponent("Web/fonts", isDirectory: true)
        let files = folder.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? []
        for file in files where file.pathExtension == "ttf" {
            // Already registered is not an error worth stopping for.
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }()

    /// Registers the fonts for this process, once.
    static func register() {
        _ = registered
    }
}

/// The two typefaces of a generated cover.
@MainActor
enum CoverFonts {
    /// Fraunces SemiBold, as the title is set in the mockup.
    static func title(size: CGFloat) -> NSFont {
        NSFont(name: "Fraunces-SemiBold", size: size) ?? NSFont(name: "Fraunces", size: size)
            ?? NSFont(descriptor: NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)!, size: size)
            ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// EB Garamond Italic.
    static func author(size: CGFloat) -> NSFont {
        NSFont(name: "EBGaramond-Italic", size: size)
            ?? NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }
}
