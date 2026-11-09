import Foundation
import OSLog

/// A passage the reader marked, anchored by the CFI of its range so it comes back at the same words
/// whatever the font or window size.
struct Highlight: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var cfi: String
    /// The marked words, for the list.
    var text: String
    var chapterTitle: String?
    /// How far into the book it is, 0...1, for keeping the list in reading order.
    var fraction: Double
    var created: Date

    init(id: UUID = UUID(), cfi: String, text: String, chapterTitle: String? = nil,
         fraction: Double, created: Date = Date()) {
        self.id = id
        self.cfi = cfi
        self.text = text
        self.chapterTitle = chapterTitle
        self.fraction = fraction
        self.created = created
    }
}

/// The highlights of each book, one small file a book in `directory`. Few are ever written, so each
/// change replaces its file whole at once. A file that can't be read is as good as none.
actor HighlightStore {
    private nonisolated let directory: URL
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "HighlightStore")
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's own, in its Application Support folder.
    static let standard = HighlightStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Highlights", isDirectory: true))

    /// A book's highlights in reading order.
    func highlights(bookID: String) -> [Highlight] {
        guard let data = try? Data(contentsOf: file(for: bookID)),
              let all = try? JSONDecoder.highlights.decode([Highlight].self, from: data)
        else { return [] }
        return all.sorted { ($0.fraction, $0.created) < ($1.fraction, $1.created) }
    }

    /// Adds it. Marking the same passage again leaves the first as it is.
    func add(_ highlight: Highlight, bookID: String) {
        var all = highlights(bookID: bookID)
        guard !all.contains(where: { $0.cfi == highlight.cfi }) else { return }
        all.append(highlight)
        write(all, bookID: bookID)
    }

    func remove(id: UUID, bookID: String) {
        let all = highlights(bookID: bookID)
        let kept = all.filter { $0.id != id }
        guard kept.count != all.count else { return }
        write(kept, bookID: bookID)
    }

    /// Deletes every highlight of the book.
    func remove(bookID: String) {
        try? FileManager.default.removeItem(at: file(for: bookID))
    }

    private func write(_ all: [Highlight], bookID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder.highlights.encode(all).write(to: file(for: bookID), options: .atomic)
        } catch {
            Self.log.error("Saving highlights failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Anything but letters, digits, `-` and `_` is percent-encoded, so every ID has a file of its own.
    private nonisolated func file(for bookID: String) -> URL {
        let name = bookID.addingPercentEncoding(withAllowedCharacters: Self.plain) ?? bookID
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }
}

private extension JSONEncoder {
    static var highlights: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var highlights: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
