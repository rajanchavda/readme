import Foundation
import OSLog

/// The books in the library, kept in `directory`: `library.json`, the copies in `Books` and the
/// covers in `Covers`. Every change is written at once, replacing the file whole. A library file
/// that can't be read is as good as none. Files are written off the main thread, so a change is on
/// disk a moment after it's made; `saved()` returns when it is.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let directory: URL
    private let positions: PositionStore
    /// What the reader marked in each book.
    let highlights: HighlightStore
    /// The picture of the spread each book was left on, for launching straight back into it.
    let spreads: LastSpreadCache
    private let now: () -> Date
    private var removing: Task<Void, Never>?
    private let file: LibraryFile
    private var unsaved: [Book]?
    private var saving: Task<Void, Never>?
    /// Imports under way, by book ID, so the same book imported twice at once is imported once.
    var imports: [String: Task<Book, any Error>] = [:]
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryStore")

    /// The app's own, in its Application Support folder.
    static let standard = LibraryStore(
        directory: URL.applicationSupportDirectory, positions: .standard, highlights: .standard)

    /// Places are kept in `directory/Positions` unless `positions` says otherwise, which is where
    /// `PositionStore.standard` keeps them when `directory` is the Application Support folder.
    init(directory: URL, positions: PositionStore? = nil, highlights: HighlightStore? = nil,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.highlights = highlights ?? HighlightStore(directory: directory.appendingPathComponent("Highlights", isDirectory: true))
        self.positions = positions ?? PositionStore(directory: directory.appendingPathComponent("Positions", isDirectory: true))
        self.now = now
        spreads = LastSpreadCache(directory: directory.appendingPathComponent("LastSpreads", isDirectory: true))
        file = LibraryFile(directory: directory)
        books = Self.load(from: directory.appendingPathComponent("library.json", isDirectory: false))
    }

    var booksDirectory: URL { directory.appendingPathComponent("Books", isDirectory: true) }
    var coversDirectory: URL { directory.appendingPathComponent("Covers", isDirectory: true) }

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

    /// Takes out, quietly, every book whose copy has gone, and returns them.
    @discardableResult
    func removeMissing(fileExists: (URL) -> Bool) -> [Book] {
        let missing = books.filter { !fileExists(fileURL(for: $0)) }
        for book in missing { remove(id: book.id) }
        return missing
    }

    /// Hears a book being taken out, at once, before anything of it is deleted.
    var onRemove: ((String) -> Void)?
    /// Waited for before a removed book's files are deleted, so a place still being written for it
    /// is gone too.
    var beforeDeleting: (() async -> Void)?

    /// Takes the book out, and deletes its copy, its cover, its saved place, its highlights and its last spread.
    func remove(id: String) {
        guard let book = book(id: id) else { return }
        books.removeAll { $0.id == id }
        save()
        onRemove?(id)
        let waitForWrites = beforeDeleting
        let copy = fileURL(for: book)
        let cover = coverURL(for: book)
        let previous = removing
        removing = Task { [positions, highlights, spreads] in
            await previous?.value
            await waitForWrites?()
            await Task.detached {
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.removeItem(at: cover)
            }.value
            await positions.remove(bookID: id)
            await highlights.remove(bookID: id)
            await spreads.remove(bookID: id)
        }
    }

    /// Returns once the copies, covers, saved places and last spreads of every book removed so far are gone.
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

    /// Returns once every change made so far is written.
    func saved() async {
        await saving?.value
    }

    /// Of the changes waiting, only the newest is written.
    private func save() {
        unsaved = books
        guard saving == nil else { return }
        saving = Task { [weak self, file] in
            while let self, let snapshot = self.unsaved {
                self.unsaved = nil
                await file.write(snapshot)
            }
            self?.saving = nil
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

/// Writes `library.json`, whole and atomically, off the main thread.
private actor LibraryFile {
    private let directory: URL
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryStore")

    init(directory: URL) {
        self.directory = directory
    }

    func write(_ books: [Book]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(books)
                .write(to: directory.appendingPathComponent("library.json", isDirectory: false), options: .atomic)
        } catch {
            Self.log.error("Saving the library failed: \(String(describing: error), privacy: .public)")
        }
    }
}
