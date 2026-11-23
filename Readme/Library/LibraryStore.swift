import Foundation
import OSLog

/// The books in the library, kept in `directory`: `library.json`, the collections in
/// `collections.json`, the copies in `Books` and the covers in `Covers`. Every change is written at once, replacing the file whole. A library file
/// that can't be read is as good as none. Files are written off the main thread, so a change is on
/// disk a moment after it's made; `saved()` returns when it is.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    /// The reader's collections, by name.
    @Published private(set) var collections: [BookCollection] = []

    private let directory: URL
    /// Where the reader left each book.
    let positions: PositionStore
    /// What the reader marked in each book.
    let highlights: HighlightStore
    /// The page the reader marked in each book.
    let markers: MarkerStore
    /// The picture of the spread each book was left on, for launching straight back into it.
    let spreads: LastSpreadCache
    private let now: () -> Date
    private var removing: Task<Void, Never>?
    private let library: Writer<[Book]>
    private let collectionsFile: Writer<[BookCollection]>
    /// Imports under way, by book ID, so the same book imported twice at once is imported once.
    var imports: [String: Task<Book, any Error>] = [:]
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryStore")

    /// The app's own, in its Application Support folder.
    static let standard = LibraryStore(
        directory: URL.applicationSupportDirectory, positions: .standard, highlights: .standard, markers: .standard)

    /// Places are kept in `directory/Positions` unless `positions` says otherwise, which is where
    /// `PositionStore.standard` keeps them when `directory` is the Application Support folder.
    init(directory: URL, positions: PositionStore? = nil, highlights: HighlightStore? = nil,
         markers: MarkerStore? = nil, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.highlights = highlights ?? HighlightStore(directory: directory.appendingPathComponent("Highlights", isDirectory: true))
        self.markers = markers ?? MarkerStore(directory: directory.appendingPathComponent("Markers", isDirectory: true))
        self.positions = positions ?? PositionStore(directory: directory.appendingPathComponent("Positions", isDirectory: true))
        self.now = now
        spreads = LastSpreadCache(directory: directory.appendingPathComponent("LastSpreads", isDirectory: true))
        library = Writer(JSONFile(directory: directory, name: "library.json"))
        collectionsFile = Writer(JSONFile(directory: directory, name: "collections.json"))
        books = Self.load(from: directory.appendingPathComponent("library.json", isDirectory: false))
        let (collections, readable) = Self.loadCollections(
            from: directory.appendingPathComponent("collections.json", isDirectory: false))
        self.collections = collections.sorted(by: Self.byName)
        // A book pointing at a collection that's gone lets go of it, and the next save drops it. Not
        // when the collections couldn't be read, though, or one bad file would empty every collection.
        if readable {
            let known = Set(collections.map(\.id))
            for index in books.indices { books[index].collectionIDs.removeAll { !known.contains($0) } }
        }
    }

    var booksDirectory: URL { directory.appendingPathComponent("Books", isDirectory: true) }
    var coversDirectory: URL { directory.appendingPathComponent("Covers", isDirectory: true) }

    /// The book last read, or if none has been, the one added last.
    var current: Book? {
        books.filter { $0.lastReadAt != nil }.max { $0.lastReadAt! < $1.lastReadAt! }
            ?? books.max { $0.addedAt < $1.addedAt }
    }

    /// The rest: the pinned ones first, the latest pin first, then the others latest first. A book
    /// never read counts from when it was added.
    var others: [Book] {
        let current = current
        let rest = books.filter { $0.id != current?.id }
        let pinned = rest.filter { $0.pinnedAt != nil }.sorted { $0.pinnedAt! > $1.pinnedAt! }
        let unpinned = rest.filter { $0.pinnedAt == nil }.sorted { $0.recency > $1.recency }
        return pinned + unpinned
    }

    /// Pins the books to the front of the shelf, or unpins them. A book pinned already keeps its pin,
    /// and so its place among the pins. IDs not in the library are passed over.
    func setPinned(ids: [String], pinned: Bool) {
        let moment = now()
        var changed = false
        for index in books.indices where ids.contains(books[index].id) {
            let value = pinned ? books[index].pinnedAt ?? moment : nil
            guard books[index].pinnedAt != value else { continue }
            books[index].pinnedAt = value
            changed = true
        }
        if changed { save() }
    }

    /// Pins the book as it was pinned elsewhere, at `date`, for an import.
    func restorePin(id: String, at date: Date) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].pinnedAt = date
        save()
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

    /// Takes the book out, and deletes its copy, its cover, its saved place, its highlights, its marker and its last spread.
    func remove(id: String) {
        guard let book = book(id: id) else { return }
        books.removeAll { $0.id == id }
        save()
        onRemove?(id)
        let waitForWrites = beforeDeleting
        let copy = fileURL(for: book)
        let cover = coverURL(for: book)
        let previous = removing
        removing = Task { [positions, highlights, markers, spreads] in
            await previous?.value
            await waitForWrites?()
            await Task.detached {
                try? FileManager.default.removeItem(at: copy)
                try? FileManager.default.removeItem(at: cover)
            }.value
            await positions.remove(bookID: id)
            await highlights.remove(bookID: id)
            await markers.remove(bookID: id)
            await spreads.remove(bookID: id)
        }
    }

    /// Returns once the copies, covers, saved places, highlights, markers and last spreads of every book removed so far are gone.
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

    /// What an imported bundle says about a book: when it was added, if given; the later of the two
    /// read dates; and, with `location`, the chapter the shelf shows. A book not here is left alone.
    func applyImported(id: String, addedAt: Date?, lastReadAt: Date?, location: ReaderLocation?) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        if let addedAt { books[index].addedAt = addedAt }
        if let lastReadAt, books[index].lastReadAt.map({ lastReadAt > $0 }) ?? true {
            books[index].lastReadAt = lastReadAt
        }
        if let location {
            books[index].chapterTitle = location.chapterTitle
            books[index].chapterMinutesLeft = location.chapterMinutesLeft
        }
        save()
    }

    /// The title and author the shelf shows, as another Mac's shelf showed them.
    func setDetails(id: String, title: String, author: String?) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        books[index].title = title
        books[index].author = author
        save()
    }

    // MARK: Collections

    func collection(id: UUID) -> BookCollection? {
        collections.first { $0.id == id }
    }

    /// The collection with this name, whatever its case and accents.
    func collection(named name: String) -> BookCollection? {
        let key = BookCollection.key(name)
        return collections.first { BookCollection.key($0.name) == key }
    }

    /// Makes a collection, or, if one has this name already, whatever its case and accents, returns
    /// that one. Nil for a name with nothing in it.
    @discardableResult
    func createCollection(name: String) -> BookCollection? {
        guard let name = BookCollection.cleanName(name) else { return nil }
        if let existing = collection(named: name) { return existing }
        let collection = BookCollection(id: UUID(), name: name, createdAt: now())
        collections = (collections + [collection]).sorted(by: Self.byName)
        saveCollections()
        return collection
    }

    /// False, changing nothing, for a name with nothing in it or one another collection has.
    @discardableResult
    func renameCollection(id: UUID, to name: String) -> Bool {
        guard let name = BookCollection.cleanName(name),
              let index = collections.firstIndex(where: { $0.id == id }),
              collection(named: name).map({ $0.id == id }) ?? true
        else { return false }
        collections[index].name = name
        collections.sort(by: Self.byName)
        saveCollections()
        return true
    }

    /// Takes the collection away, and every book out of it. The books stay in the library.
    func deleteCollection(id: UUID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        collections.removeAll { $0.id == id }
        saveCollections()
        var changed = false
        for index in books.indices where books[index].collectionIDs.contains(id) {
            books[index].collectionIDs.removeAll { $0 == id }
            changed = true
        }
        if changed { save() }
    }

    /// Puts the books in the collection, or takes them out. IDs not in the library are passed over.
    func setCollection(_ id: UUID, member: Bool, ids: [String]) {
        guard collection(id: id) != nil else { return }
        var changed = false
        for index in books.indices where ids.contains(books[index].id) {
            let has = books[index].collectionIDs.contains(id)
            if member && !has {
                books[index].collectionIDs.append(id)
                changed = true
            } else if !member && has {
                books[index].collectionIDs.removeAll { $0 == id }
                changed = true
            }
        }
        if changed { save() }
    }

    /// Puts the book in the collections with these names, making any there are none of. It's never
    /// taken out of one, for an import.
    func joinCollections(named names: [String], id bookID: String) {
        for name in names {
            guard let collection = createCollection(name: name) else { continue }
            setCollection(collection.id, member: true, ids: [bookID])
        }
    }

    private nonisolated static func byName(_ a: BookCollection, _ b: BookCollection) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    func fileURL(for book: Book) -> URL {
        booksDirectory.appendingPathComponent(book.fileName, isDirectory: false)
    }

    func coverURL(for book: Book) -> URL {
        coversDirectory.appendingPathComponent(book.id + ".png", isDirectory: false)
    }

    /// Returns once every change made so far is written.
    func saved() async {
        await library.saved()
        await collectionsFile.saved()
    }

    private func save() {
        library.save(books)
    }

    private func saveCollections() {
        collectionsFile.save(collections)
    }

    /// The collections, and whether the file could be read: a missing file can, as there are none yet.
    private static func loadCollections(from file: URL) -> ([BookCollection], readable: Bool) {
        guard let data = try? Data(contentsOf: file) else { return ([], !FileManager.default.fileExists(atPath: file.path)) }
        do {
            return (try JSONDecoder().decode([BookCollection].self, from: data), true)
        } catch {
            log.error("The collections file could not be read: \(String(describing: error), privacy: .public)")
            return ([], false)
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

/// Keeps one file up to date: of the changes waiting, only the newest is written.
@MainActor
private final class Writer<Value: Encodable & Sendable> {
    private let file: JSONFile
    private var unsaved: Value?
    private var saving: Task<Void, Never>?

    init(_ file: JSONFile) {
        self.file = file
    }

    func save(_ value: Value) {
        unsaved = value
        guard saving == nil else { return }
        saving = Task { [weak self, file] in
            while let self, let snapshot = self.unsaved {
                self.unsaved = nil
                await file.write(snapshot)
            }
            self?.saving = nil
        }
    }

    /// Returns once every change made so far is written.
    func saved() async {
        await saving?.value
    }
}

/// Writes one of the library's files, whole and atomically, off the main thread.
private actor JSONFile {
    private let directory: URL
    private let name: String
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryStore")

    init(directory: URL, name: String) {
        self.directory = directory
        self.name = name
    }

    func write(_ value: some Encodable & Sendable) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value)
                .write(to: directory.appendingPathComponent(name, isDirectory: false), options: .atomic)
        } catch {
            Self.log.error("Saving \(self.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
