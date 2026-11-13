import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A `.readmelibrary` file: books and what the reader did in them, for another Mac.
    static let readmeLibrary = UTType(exportedAs: "com.rajanchavda.Readme.library")
}

/// What a bundle says about itself.
struct BundleManifest: Codable, Equatable, Sendable {
    /// The newest layout this Readme can read.
    static let currentVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    var bookIDs: [String]
}

/// A book as the shelf shows it, as it travels in a bundle.
struct BundledBook: Codable, Equatable, Sendable {
    var title: String
    var author: String?
    var addedAt: Date
    var lastReadAt: Date?
    /// When it was pinned to the front of the shelf. Bundles from before pins have none.
    var pinnedAt: Date? = nil
}

/// One book to put in a bundle.
struct BundleItem: Sendable {
    var id: String
    var info: BundledBook
    var epub: URL
    var highlights: [Highlight]
    var marker: Marker?
    var position: ReaderLocation?
}

/// One book's notes, as read back from a bundle.
struct BundleContents: Equatable, Sendable {
    var info: BundledBook
    var highlights: [Highlight]
    var marker: Marker?
    var position: ReaderLocation?
}

enum BundleError: Error, Equatable, Sendable {
    case notABundle
    case newerVersion
    case tooLarge
    case unwritable

    var message: String {
        switch self {
        case .notABundle: "This file isn't a Readme library."
        case .newerVersion: "This library was made by a newer Readme. Update Readme to import it."
        case .tooLarge: "That's more than 4 GB, too much for one file. Export fewer books at a time."
        case .unwritable: "The export couldn't be saved."
        }
    }
}

/// A `.readmelibrary` file: a zip of stored entries laid out as
///
///     manifest.json
///     books/<id>/book.json, book.epub, highlights.json, marker.json?, position.json?
///
/// Book IDs are the SHA-256 of the EPUB, so a bundle whose IDs are anything else is refused before
/// one of them is ever used as a path.
enum LibraryBundle {
    static let maxBookSize = 1 << 31
    static let maxNotesSize = 64 << 20

    static func write(_ items: [BundleItem], to url: URL, exportedAt: Date) throws(BundleError) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let writer = try ZipWriter(url: url)
            let manifest = BundleManifest(
                formatVersion: BundleManifest.currentVersion, exportedAt: exportedAt, bookIDs: items.map(\.id))
            try writer.add("manifest.json", data: encoder.encode(manifest))
            for item in items {
                let folder = "books/\(item.id)/"
                try writer.add(folder + "book.json", data: encoder.encode(item.info))
                try writer.add(folder + "highlights.json", data: encoder.encode(item.highlights))
                if let marker = item.marker { try writer.add(folder + "marker.json", data: encoder.encode(marker)) }
                if let position = item.position { try writer.add(folder + "position.json", data: encoder.encode(position)) }
                try writer.add(folder + "book.epub", contentsOf: item.epub)
            }
            try writer.finish()
        } catch ZipWriter.Failure.tooLarge {
            throw .tooLarge
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw .unwritable
        }
    }

    static func open(_ url: URL) throws(BundleError) -> OpenedBundle {
        guard let archive = ZipArchive(url),
              let data = archive.data(for: "manifest.json", limit: maxNotesSize),
              let manifest = try? OpenedBundle.decoder.decode(BundleManifest.self, from: data)
        else { throw .notABundle }
        guard manifest.formatVersion <= BundleManifest.currentVersion else { throw .newerVersion }
        for id in manifest.bookIDs {
            guard isBookID(id), archive.contains("books/\(id)/book.json"), archive.contains("books/\(id)/book.epub")
            else { throw .notABundle }
        }
        return OpenedBundle(url: url, manifest: manifest)
    }

    /// 64 lowercase hex digits, as `BookID` makes them.
    static func isBookID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// A bundle that has been checked, ready to read books from.
struct OpenedBundle: Sendable {
    let url: URL
    let manifest: BundleManifest

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func contents(of id: String) throws(BundleError) -> BundleContents {
        guard LibraryBundle.isBookID(id), let archive = ZipArchive(url) else { throw .notABundle }
        let folder = "books/\(id)/"
        let decoder = Self.decoder
        func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            archive.data(for: folder + name, limit: LibraryBundle.maxNotesSize)
                .flatMap { try? decoder.decode(type, from: $0) }
        }
        guard let info = read(BundledBook.self, "book.json") else { throw .notABundle }
        return BundleContents(
            info: info,
            highlights: read([Highlight].self, "highlights.json") ?? [],
            marker: read(Marker.self, "marker.json"),
            position: read(ReaderLocation.self, "position.json"))
    }

    /// Writes the book's EPUB to `destination`, replacing anything there.
    func extractEPUB(of id: String, to destination: URL) throws(BundleError) {
        guard LibraryBundle.isBookID(id), let archive = ZipArchive(url),
              let data = archive.data(for: "books/\(id)/book.epub", limit: LibraryBundle.maxBookSize)
        else { throw .notABundle }
        do { try data.write(to: destination, options: .atomic) } catch { throw .unwritable }
    }
}
