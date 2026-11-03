import AppKit
import CoreText
import OSLog

/// The fonts the app ships in `Web/fonts`, made known to AppKit and SwiftUI. The reading web view
/// has its own `@font-face`, which SwiftUI can't use.
enum BundledFonts {
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "BundledFonts")

    private static let registered: Void = {
        let folder = Bundle(for: BundleToken.self).resourceURL?
            .appendingPathComponent("Web/fonts", isDirectory: true)
        let files = folder.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? []
        for file in files where file.pathExtension == "ttf" {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error),
                let error = error?.takeRetainedValue(),
                // Already registered is not an error worth reporting.
                CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue
            {
                log.error("Registering \(file.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
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
            ?? NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
            ?? .systemFont(ofSize: size, weight: .semibold)
    }

    /// EB Garamond Italic.
    static func author(size: CGFloat) -> NSFont {
        NSFont(name: "EBGaramond-Italic", size: size)
            ?? NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }
}
