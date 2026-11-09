import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// A picture of the spread each book was last left on, so launching into a book can show it at once
/// while the book itself opens behind it. Each is kept with a signature of the look it was taken in,
/// the window's size, its scale and the book's styles, and is only given back for the same look:
/// a picture of the wrong size or theme is worse than none.
///
/// Pictures are written off the main thread. Of a book's pictures waiting, only the newest is
/// written; `written()` returns once they all are.
@MainActor
final class LastSpreadCache {
    nonisolated let directory: URL
    private var unsaved: [String: Entry] = [:]
    private var saving: Task<Void, Never>?
    private nonisolated static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LastSpreadCache")

    private struct Entry: @unchecked Sendable {
        var image: CGImage
        var signature: String
    }

    nonisolated init(directory: URL) {
        self.directory = directory
    }

    /// The signature for a look: everything that changes how a spread is drawn.
    nonisolated static func signature(size: CGSize, scale: CGFloat, columns: Int, columnWidth: Double?, css: String) -> String {
        let styles = SHA256.hash(data: Data(css.utf8)).map { String(format: "%02x", $0) }.joined()
        let width = columnWidth.map { String(format: "%.1f", $0) } ?? "auto"
        return String(format: "%.0fx%.0f@%.1f", size.width, size.height, scale) + " \(columns)x\(width) \(styles)"
    }

    nonisolated func imageURL(bookID: String) -> URL {
        directory.appendingPathComponent(Self.name(bookID) + ".png", isDirectory: false)
    }

    nonisolated private func signatureURL(bookID: String) -> URL {
        directory.appendingPathComponent(Self.name(bookID) + ".look", isDirectory: false)
    }

    /// The book's last spread, if one was kept for exactly this look. Read from disk at once.
    nonisolated func image(bookID: String, signature: String) -> CGImage? {
        guard let kept = try? String(contentsOf: signatureURL(bookID: bookID), encoding: .utf8), kept == signature,
              let source = CGImageSourceCreateWithURL(imageURL(bookID: bookID) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func save(_ image: CGImage, signature: String, bookID: String) {
        unsaved[bookID] = Entry(image: image, signature: signature)
        guard saving == nil else { return }
        saving = Task { [weak self] in
            while let self, let (bookID, entry) = self.unsaved.first {
                self.unsaved[bookID] = nil
                await self.write(entry, bookID: bookID)
            }
            self?.saving = nil
        }
    }

    /// Returns once every picture given so far is written.
    func written() async {
        await saving?.value
    }

    /// Deletes the book's picture, after any still being written.
    func remove(bookID: String) async {
        unsaved[bookID] = nil
        await written()
        let files = [imageURL(bookID: bookID), signatureURL(bookID: bookID)]
        await Task.detached {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }.value
    }

    /// The signature goes last, and first is taken away, so a picture half replaced is never matched.
    private func write(_ entry: Entry, bookID: String) async {
        let directory = directory
        let imageFile = imageURL(bookID: bookID)
        let signatureFile = signatureURL(bookID: bookID)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: signatureFile)
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.png.identifier as CFString, 1, nil)
                else { return }
                CGImageDestinationAddImage(destination, entry.image, nil)
                guard CGImageDestinationFinalize(destination) else { return }
                try (output as Data).write(to: imageFile, options: .atomic)
                try Data(entry.signature.utf8).write(to: signatureFile, options: .atomic)
            } catch {
                Self.log.error("Keeping the last spread failed: \(String(describing: error), privacy: .public)")
            }
        }.value
    }

    private nonisolated static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    private nonisolated static func name(_ bookID: String) -> String {
        bookID.addingPercentEncoding(withAllowedCharacters: plain) ?? bookID
    }
}
