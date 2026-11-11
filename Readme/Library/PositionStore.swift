import CryptoKit
import Foundation
import OSLog

/// Where the reader left each book, one small file a book in `directory`. It works off the main
/// thread, and each save replaces its file whole, so a file is either the old place or the new one.
/// One that can't be read is as good as none.
actor PositionStore {
    private nonisolated let directory: URL
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

    /// The same, read at once on the caller's thread, for launching straight into a book. A save
    /// under way is either read whole or not at all.
    nonisolated func locationNow(bookID: String) -> ReaderLocation? {
        guard let data = try? Data(contentsOf: file(for: bookID)) else { return nil }
        return try? JSONDecoder().decode(ReaderLocation.self, from: data)
    }

    func remove(bookID: String) {
        try? FileManager.default.removeItem(at: file(for: bookID))
    }

    /// Anything but letters, digits, `-` and `_` is percent-encoded, so every ID has a file of its own
    /// in the folder.
    private nonisolated func file(for bookID: String) -> URL {
        let name = bookID.addingPercentEncoding(withAllowedCharacters: Self.plain) ?? bookID
        return directory.appendingPathComponent(name + ".json", isDirectory: false)
    }
}

/// How an imported place is weighed against the one already here.
enum ImportMerge {
    /// Whether `incoming` is further into the book than `existing`, or there's no place here at all.
    static func isFurther(_ incoming: ReaderLocation, than existing: ReaderLocation?) -> Bool {
        guard let existing else { return true }
        return incoming.fraction > existing.fraction
    }
}

/// Writes places to a store one at a time, off the main thread, so a reader turning pages quickly
/// never waits on the disk. Of a book's places waiting, only the newest is written.
@MainActor
final class PlaceWriter {
    private let store: PositionStore
    /// By book, so one book's place isn't lost to another's.
    private var unsaved: [String: ReaderLocation] = [:]
    private var saving: Task<Void, Never>?

    init(store: PositionStore) {
        self.store = store
    }

    func save(_ location: ReaderLocation, bookID: String) {
        unsaved[bookID] = location
        guard saving == nil else { return }
        saving = Task { [weak self, store] in
            while let self, let (bookID, location) = self.unsaved.first {
                self.unsaved[bookID] = nil
                await store.save(location, bookID: bookID)
            }
            self?.saving = nil
        }
    }

    /// Returns once every place given so far is written.
    func written() async {
        await saving?.value
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
