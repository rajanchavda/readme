import AppKit
import ImageIO
import SwiftUI

/// A book's cover at `width`, always 2:3. The book's own cover fills it, cropped; a book without one,
/// or whose cover can't be read, gets a typographic cover from its title and author.
struct BookCoverView: View {
    let book: Book
    let width: CGFloat
    let library: LibraryStore

    /// What a cover's state belongs to. A state for any other key isn't shown.
    struct Key: Hashable {
        var id: String
        var hasCover: Bool
        var width: CGFloat
    }

    enum State {
        case loading
        case loaded(CGImage)
        case failed
    }

    struct Resolved {
        var key: Key
        var state: State
    }

    @SwiftUI.State private var resolved: Resolved?

    init(book: Book, width: CGFloat, library: LibraryStore) {
        self.book = book
        self.width = width
        self.library = library
    }

    private var key: Key { Key(id: book.id, hasCover: book.hasCover, width: width) }

    var body: some View {
        let palette = GeneratedCover.palette(for: book)
        ZStack {
            switch Self.shown(resolved, for: key, initial: Self.initial(book, in: library, width: width)) {
            case .loaded(let image):
                RealCover(image: image, size: size)
            case .loading:
                // The generated cover's colour, so the real one fades in over it rather than over grey.
                palette.background
            case .failed:
                GeneratedCoverView(book: book, width: width, palette: palette)
            }
            SpineHighlight()
        }
        .frame(width: width, height: size.height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 3, topTrailingRadius: 3))
        // Flattened first, so the shadow is the cover's and the lettering casts none of its own.
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: width * 0.045, x: 0, y: width * 0.035)
        .task(id: key) {
            let key = key
            let state = await Self.resolve(book, in: library, width: width)
            // A load for a book the view no longer shows must not write over the new one.
            guard !Task.isCancelled else { return }
            resolved = Resolved(key: key, state: state)
        }
    }

    private var size: CGSize { CGSize(width: width, height: width * 1.5) }

    /// What `resolved` shows, which is only its own key's: otherwise `initial`.
    static func shown(_ resolved: Resolved?, for key: Key, initial: @autoclosure () -> State) -> State {
        if let resolved, resolved.key == key { return resolved.state }
        return initial()
    }

    /// What can be shown without waiting.
    static func initial(_ book: Book, in library: LibraryStore, width: CGFloat) -> State {
        guard book.hasCover else { return .failed }
        let url = library.coverURL(for: book)
        if let image = CoverImages.cached(url, width: width) { return .loaded(image) }
        // Only where it starts: loading looks again.
        return CoverImages.knownUnreadable(url) ? .failed : .loading
    }

    /// The cover as it turns out: the book's own, or failed, which is the generated one.
    static func resolve(_ book: Book, in library: LibraryStore, width: CGFloat) async -> State {
        guard book.hasCover else { return .failed }
        guard let image = await CoverImages.load(library.coverURL(for: book), width: width) else { return .failed }
        return .loaded(image)
    }
}

/// The edge of the book's spine, from the mockup.
private struct SpineHighlight: View {
    var body: some View {
        GeometryReader { geometry in
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.2), location: 0),
                    .init(color: .white.opacity(0.08), location: 0.6),
                    .init(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geometry.size.width * 0.05)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .allowsHitTesting(false)
    }
}

private struct RealCover: View {
    let image: CGImage
    let size: CGSize

    var body: some View {
        let fill = CoverImages.fillRect(imageSize: CGSize(width: image.width, height: image.height), in: size)
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: fill.width, height: fill.height)
            .frame(width: size.width, height: size.height)
            .clipped()
    }
}

private struct GeneratedCoverView: View {
    let book: Book
    let width: CGFloat
    let palette: CoverPalette

    var body: some View {
        let layout = GeneratedCover.layout(title: book.title, author: book.author, width: width)
        let padding = width * GeneratedCover.padding
        ZStack {
            palette.background
            VStack(alignment: .leading, spacing: 0) {
                lines(layout.title, font: CoverFonts.title)
                Spacer(minLength: 0)
                if let author = layout.author {
                    lines(author, font: CoverFonts.author).opacity(0.85)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(padding)
            .foregroundStyle(palette.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([book.title, book.author].compactMap { $0 }.joined(separator: ", "))
    }

    /// One `Text` a line, so the lines are the ones that were measured.
    private func lines(_ text: GeneratedCover.Lines, font: (CGFloat) -> NSFont) -> some View {
        let nsFont = font(text.size)
        let natural = nsFont.ascender - nsFont.descender + nsFont.leading
        return VStack(alignment: .leading, spacing: text.size * GeneratedCover.lineHeight - natural) {
            ForEach(Array(text.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(Font(nsFont)).lineLimit(1).fixedSize()
            }
        }
    }
}

/// Decoded covers, kept so a scrolling shelf doesn't decode them again.
enum CoverImages {
    private final class Box: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = byteLimit
        return cache
    }()

    /// What the cache may hold, in bytes of decoded pixels.
    static let byteLimit = 64 * 1024 * 1024

    /// Enough pixels for a retina screen.
    private static func pixels(_ width: CGFloat) -> Int { Int((width * 1.5 * 2).rounded(.up)) }

    private static func key(_ url: URL, _ width: CGFloat) -> NSString {
        "\(url.path)@\(pixels(width))" as NSString
    }

    nonisolated(unsafe) private static let unreadable = NSCache<NSString, NSNumber>()

    /// Whether the last try at this cover found nothing to show.
    static func knownUnreadable(_ url: URL) -> Bool {
        unreadable.object(forKey: url.path as NSString) != nil
    }

    static func cached(_ url: URL, width: CGFloat) -> CGImage? {
        cache.object(forKey: key(url, width))?.image
    }

    /// The cover at `url`, decoded off the main thread and no larger than the view needs. Nil if the
    /// file is missing or isn't an image, or if the caller is cancelled, which leaves nothing behind.
    static func load(_ url: URL, width: CGFloat) async -> CGImage? {
        if Task.isCancelled { return nil }
        if let image = cached(url, width: width) { return image }
        let maxPixels = pixels(width)
        let decoding = Task.detached(priority: .userInitiated) { () -> Box? in
            guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Box.init)
        }
        // A detached task doesn't inherit cancellation, so it's passed on.
        let box = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
        if Task.isCancelled { return nil }
        guard let box else {
            unreadable.setObject(1, forKey: url.path as NSString)
            return nil
        }
        unreadable.removeObject(forKey: url.path as NSString)
        cache.setObject(box, forKey: key(url, width), cost: box.image.width * box.image.height * 4)
        return box.image
    }

    /// The size an image is drawn at to fill `frame` with none of it empty. It is then centred and cropped.
    static func fillRect(imageSize: CGSize, in frame: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return frame }
        let scale = max(frame.width / imageSize.width, frame.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
