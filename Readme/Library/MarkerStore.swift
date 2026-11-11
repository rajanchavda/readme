import Foundation
import OSLog

/// The reader's own "I stopped here": one page of a book they chose to mark, apart from the place the
/// book keeps by itself. `cfi` is a point at the start of the marked spread, so it comes back on the
/// spread that holds it whatever the font or window size.
struct Marker: Codable, Equatable, Sendable {
    var cfi: String
    /// How far into the book it is, 0...1.
    var fraction: Double
    /// The page it was on when marked, for telling the reader where it is.
    var page: Int
    var chapterTitle: String?
    var created: Date

    init(cfi: String, fraction: Double, page: Int, chapterTitle: String? = nil, created: Date = Date()) {
        self.cfi = cfi
        self.fraction = fraction
        self.page = page
        self.chapterTitle = chapterTitle
        // Whole seconds, as the file keeps it, so a marker read back is the one set.
        self.created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded(.down))
    }
}

/// Each book's marker, one small file a book in `directory`. Setting it again moves it. A file that
/// can't be read is as good as none.
actor MarkerStore {
    private nonisolated let directory: URL
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "MarkerStore")
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's own, in its Application Support folder.
    static let standard = MarkerStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Markers", isDirectory: true))

    func marker(bookID: String) -> Marker? {
        guard let data = try? Data(contentsOf: file(for: bookID)) else { return nil }
        return try? JSONDecoder.markers.decode(Marker.self, from: data)
    }

    func set(_ marker: Marker, bookID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder.markers.encode(marker).write(to: file(for: bookID), options: .atomic)
        } catch {
            Self.log.error("Saving a marker failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sets it only if the book has no marker yet. Returns whether it did.
    @discardableResult
    func setIfNone(_ marker: Marker, bookID: String) -> Bool {
        guard self.marker(bookID: bookID) == nil else { return false }
        set(marker, bookID: bookID)
        return true
    }

    func remove(bookID: String) {
        try? FileManager.default.removeItem(at: file(for: bookID))
    }

    /// Anything but letters, digits, `-` and `_` is percent-encoded, so every ID has a file of its own.
    private nonisolated func file(for bookID: String) -> URL {
        let name = bookID.addingPercentEncoding(withAllowedCharacters: Self.plain) ?? bookID
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }
}

private extension JSONEncoder {
    static var markers: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var markers: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
