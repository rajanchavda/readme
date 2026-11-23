import Foundation

/// A sheet for naming a collection: a new one with these books in it (none, from the chip row's +),
/// or one being renamed.
enum CollectionSheet: Identifiable, Equatable {
    case create(bookIDs: [String])
    case rename(UUID)

    var id: String {
        switch self {
        case .create(let ids): "create:" + ids.joined(separator: ",")
        case .rename(let id): "rename:" + id.uuidString
        }
    }
}

/// Which chip the shelf is showing, and what's being asked about a collection. Kept for as long as
/// the app runs, never saved, so the app always opens on All.
@MainActor
final class ShelfCollections: ObservableObject {
    /// The chip that's on.
    @Published var filter: ShelfFilter = .all

    /// The collection whose chip is on, or nil for any other chip. Setting nil goes back to All.
    var activeID: UUID? {
        get {
            if case .collection(let id) = filter { id } else { nil }
        }
        set { filter = newValue.map(ShelfFilter.collection) ?? .all }
    }
    @Published var sheet: CollectionSheet?
    /// A collection with books in it that's waiting on "Delete <Name>?".
    @Published var confirmingDelete: UUID?

    /// The collection showing, or nil for All, as it is when the one that was showing has gone.
    func active(in library: LibraryStore) -> BookCollection? {
        activeID.flatMap(library.collection(id:))
    }

    /// What the shelf shows: the chip that's on, or All when its collection has gone or its built-in
    /// chip has no books left and is hidden.
    func filter(in library: LibraryStore) -> ShelfFilter {
        switch filter {
        case .all: .all
        case .reading, .finished: Self.builtInChips(library.books).contains(filter) ? filter : .all
        case .collection(let id): library.collection(id: id) == nil ? .all : filter
        }
    }

    func showAll() {
        filter = .all
    }

    /// Lets go of a chip that's gone, as deleting a collection does, so an emptied Reading or Finished
    /// doesn't come back on by itself when it has books again.
    func settle(in library: LibraryStore) {
        if filter(in: library) != filter { filter = .all }
    }

    /// Deletes the collection, and goes back to All if it was the one showing.
    func delete(_ id: UUID, from library: LibraryStore) {
        if activeID == id { activeID = nil }
        if confirmingDelete == id { confirmingDelete = nil }
        library.deleteCollection(id: id)
    }

    /// Books added while a collection shows go into it, or they'd vanish as they were added.
    func addImported(_ results: [Result<Book, ImportError>], to library: LibraryStore) {
        addImported(ids: results.compactMap { result -> String? in
            if case .success(let book) = result { return book.id }
            return nil
        }, to: library)
    }

    /// The same, for books a library bundle added.
    func addImported(ids: [String], to library: LibraryStore) {
        guard let active = active(in: library) else { return }
        library.setCollection(active.id, member: true, ids: ids)
    }

    /// The books as the shelf shows them, the current one first, for picking out a run with Shift-click:
    /// only those in `collection` while it's showing.
    static func shelfOrder(_ library: LibraryStore, filter: ShelfFilter) -> [String] {
        let current = [library.current].compactMap { $0 }
        return (shown(current, filter: filter) + shown(library.others, filter: filter)).map(\.id)
    }

    /// The books in `collection`, in the order they came; all of them for nil.
    nonisolated static func shown(_ books: [Book], in collection: UUID?) -> [Book] {
        shown(books, filter: collection.map(ShelfFilter.collection) ?? .all)
    }

    /// The books `filter` shows, in the order they came, except finished ones, newest finished first.
    nonisolated static func shown(_ books: [Book], filter: ShelfFilter) -> [Book] {
        switch filter {
        case .all: books
        case .reading: books.filter { $0.isStarted && !$0.isFinished }
        case .finished: books.filter(\.isFinished).sorted { $0.finishedAt! > $1.finishedAt! }
        case .collection(let id): books.filter { $0.collectionIDs.contains(id) }
        }
    }

    /// Reading and Finished, each only when it has books.
    nonisolated static func builtInChips(_ books: [Book]) -> [ShelfFilter] {
        [ShelfFilter.reading, .finished].filter { !shown(books, filter: $0).isEmpty }
    }

    /// The chip row shows once there's a collection, or once a book has been opened.
    static func showsChipRow(_ library: LibraryStore) -> Bool {
        !library.collections.isEmpty || library.books.contains(where: \.isStarted)
    }

    /// Esc over the shelf: it clears an open search, then the selection, then goes back to All.
    static func escape(search: ShelfSearch, selection: ShelfSelection, collections: ShelfCollections) {
        ShelfSearch.escape(search) {
            if selection.ids.isEmpty { collections.showAll() } else { selection.clear() }
        }
    }

    nonisolated static func emptyLine(name: String) -> String {
        "No books in \(name) yet. Right-click a book and choose Add to Collection."
    }

    nonisolated static func deleteText(name: String, count: Int) -> (title: String, message: String) {
        let message = count == 1
            ? "The 1 book in it stays in your library."
            : "The \(count) books in it stay in your library."
        return ("Delete \(name)?", message)
    }
}
