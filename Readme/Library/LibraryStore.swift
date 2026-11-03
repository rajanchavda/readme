import Foundation
import OSLog

/// The books in the library, kept in `directory`: `library.json`, the copies in `Books` and the
/// covers in `Covers`. Every change is written at once, replacing the file whole. A library file
/// that can't be read is as good as none.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let directory: URL
    private let positions: PositionStore
    private let now: () -> Date
    private var removing: Task<Void, Never>?
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryStore")

    /// The app's own, in its Application Support folder.
    static let standard = LibraryStore(directory: URL.applicationSupportDirectory)

    /// Places are kept in `directory/Positions` unless `positions` says otherwise, which is where
    /// `PositionStore.standard` keeps them when `directory` is the Application Support folder.
    init(directory: URL, positions: PositionStore? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.positions = positions ?? PositionStore(directory: directory.appendingPathComponent("Positions", isDirectory: true))
        self.now = now
        books = Self.load(from: libraryFile)
    }

    var booksDirectory: URL { directory.appendingPathComponent("Books", isDirectory: true) }
    var coversDirectory: URL { directory.appendingPathComponent("Covers", isDirectory: true) }
    private var libraryFile: URL { directory.appendingPathComponent("library.json", isDirectory: false) }

    /// The book last read, or if none has been, the one added last.
    var current: Book? {
        books.filter { $0.lastReadAt != nil }.max { $0.lastReadAt! < $1.lastReadAt! }
            ?? books.max { $0.addedAt < $1.addedAt }
    }

    /// The rest, latest first. A book never read counts from when it was added.
    var others: [Book] {
        let current = current
        return books.filter { $0.id != current?.id }.sorted { $0.recency > $1.recency }
    }

    /// A book already in the library stays as it is.
    func add(_ book: Book) {
        guard !books.contains(where: { $0.id == book.id }) else { return }
        books.append(book)
        save()
    }

    func book(id: String) -> Book? {
        books.first { $0.id == id }
    }

    /// Takes the book out, and deletes its copy, its cover and its saved place.
    func remove(id: String) {
        guard let book = book(id: id) else { return }
        books.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: fileURL(for: book))
        try? FileManager.default.removeItem(at: coverURL(for: book))
        let previous = removing
        removing = Task { [positions] in
            await previous?.value
            await positions.remove(bookID: id)
        }
    }

    /// Returns once the saved places of every book removed so far are gone.
    func removed() async {
        await removing?.value
    }

    func markRead(id: String, location: ReaderLocation) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].lastReadAt = now()
        books[index].chapterTitle = location.chapterTitle
        books[index].chapterMinutesLeft = location.chapterMinutesLeft
        save()
    }

    func fileURL(for book: Book) -> URL {
        booksDirectory.appendingPathComponent(book.fileName, isDirectory: false)
    }

    func coverURL(for book: Book) -> URL {
        coversDirectory.appendingPathComponent(book.id + ".png", isDirectory: false)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(books).write(to: libraryFile, options: .atomic)
        } catch {
            Self.log.error("Saving the library failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from file: URL) -> [Book] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try JSONDecoder().decode([Book].self, from: data)
        } catch {
            log.error("The library file could not be read: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

private extension Book {
    var recency: Date { lastReadAt ?? addedAt }
}
