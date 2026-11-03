import AppKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

enum ImportError: Error, Equatable {
    /// Not an EPUB at all.
    case notAnEPUB
    /// Locked with DRM, which the app can't open.
    case copyProtected
    /// An EPUB that couldn't be copied or opened.
    case unreadable
}

/// Adds books to a library: checks the file, copies it in, reads its title, author and cover with a
/// web view nobody sees, and records it. The same book twice is one book.
@MainActor
struct BookImporter {
    let store: LibraryStore
    private nonisolated static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "BookImporter")

    init(store: LibraryStore) {
        self.store = store
    }

    func importBook(from url: URL) async throws -> Book {
        // A file the user picked or dropped can only be read while this is open, so the copy is made
        // inside it. Nothing after that touches the original.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        try await Task.detached { try EPUBInspector.check(url) }.value

        let books = store.booksDirectory
        let staged = books.appendingPathComponent(".importing-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: staged)
            }.value
        } catch {
            Self.log.error("Copying a book failed: \(String(describing: error), privacy: .public)")
            throw ImportError.unreadable
        }

        // The copy is what's hashed, so the ID is of what's kept.
        let id: String
        do { id = try await BookID.of(staged) } catch { throw ImportError.unreadable }
        if let existing = store.book(id: id) { return existing }
        // The same book arriving twice at once waits for the first.
        if let running = store.imports[id] { return try await running.value }
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let task = Task { try await finish(staged, id: id, fallbackTitle: fallbackTitle) }
        store.imports[id] = task
        defer { store.imports[id] = nil }
        return try await task.value
    }

    /// Reads the staged copy's details, moves it into place and records the book.
    private func finish(_ staged: URL, id: String, fallbackTitle: String) async throws -> Book {
        let (info, cover) = try await details(of: staged)
        // Another import may have added it while the book was being read.
        if let existing = store.book(id: id) { return existing }
        var book = Book(
            id: id,
            title: info?.title ?? fallbackTitle,
            author: info?.author,
            fileName: id + ".epub",
            hasCover: false,
            addedAt: Date(),
            lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
        let copy = store.fileURL(for: book)
        let coverFile = store.coverURL(for: book)
        let covers = store.coversDirectory
        do {
            book.hasCover = try await Task.detached {
                let fileManager = FileManager.default
                // A copy left by an import that never finished is replaced.
                try? fileManager.removeItem(at: copy)
                try fileManager.moveItem(at: staged, to: copy)
                try? fileManager.removeItem(at: coverFile)
                guard let png = cover.flatMap(CoverImage.png(from:)) else { return false }
                do {
                    try fileManager.createDirectory(at: covers, withIntermediateDirectories: true)
                    try png.write(to: coverFile, options: .atomic)
                    return true
                } catch {
                    Self.log.error("Saving a cover failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }.value
        } catch {
            Self.log.error("Placing a book failed: \(String(describing: error), privacy: .public)")
            throw ImportError.unreadable
        }
        store.add(book)
        return book
    }

    /// Imports each in turn, whatever happens to the others.
    func importAll(_ urls: [URL]) async -> [Result<Book, ImportError>] {
        var results: [Result<Book, ImportError>] = []
        for url in urls {
            do {
                results.append(.success(try await importBook(from: url)))
            } catch let error as ImportError {
                results.append(.failure(error))
            } catch {
                results.append(.failure(.unreadable))
            }
        }
        return results
    }

    /// Opens the book in a hidden view, which is let go of as soon as it has answered. A book that
    /// won't open throws `.unreadable`, and one that opens but won't say is listed by its file name.
    private func details(of file: URL) async throws -> (BookWebView.Info?, Data?) {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let view = BookWebView(frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            _ = try await view.open(file, at: nil)
        } catch {
            Self.log.error("Opening a book to import it failed: \(String(describing: error), privacy: .public)")
            throw ImportError.unreadable
        }
        return (await view.info(), await view.coverData())
    }
}

/// Covers as the library keeps them.
enum CoverImage {
    /// The longest side, in pixels. Covers are shown a few hundred points tall, so this leaves room
    /// for a large display and keeps the library small.
    static let maxSide = 1200

    /// The image as PNG, scaled down to `maxSide` if it's larger and left at its size if not. Nil if
    /// the data isn't an image.
    static func png(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var image = original
        if max(original.width, original.height) > maxSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            image = scaled
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
