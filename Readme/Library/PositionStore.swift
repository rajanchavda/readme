import CryptoKit
import Foundation
import OSLog

/// Where the reader left each book, one small file a book in `directory`. It works off the main
/// thread, and each save replaces its file whole, so a file is either the old place or the new one.
/// One that can't be read is as good as none.
actor PositionStore {
    private let directory: URL
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "PositionStore")
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's own, in its Application Support folder.
    static let standard = PositionStore(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Positions", isDirectory: true))

    func save(_ location: ReaderLocation, bookID: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(location).write(to: file(for: bookID), options: .atomic)
        } catch {
            Self.log.error("Saving a place failed: \(String(describing: error), privacy: .public)")
        }
    }

    func location(bookID: String) -> ReaderLocation? {
        guard let data = try? Data(contentsOf: file(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(ReaderLocation.self, from: data)
    }

    func remove(bookID: String) {
        try? FileManager.default.removeItem(at: file(for: bookID))
    }

    /// Anything but letters, digits, `-` and `_` is percent-encoded, so every ID has a file of its own
    /// in the folder.
    private func file(for bookID: String) -> URL {
        let name = bookID.addingPercentEncoding(withAllowedCharacters: Self.plain) ?? bookID
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }
}

/// Which book a file is, until the library gives each book an ID of its own: the SHA-256 of the file's
/// contents, so the same book has the same ID wherever it's kept and whatever it's called.
enum BookID {
    private static let chunk = 1 << 20

    /// Reads the file a megabyte at a time, off the main thread.
    static func of(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: chunk), !data.isEmpty {
                hash.update(data: data)
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}
