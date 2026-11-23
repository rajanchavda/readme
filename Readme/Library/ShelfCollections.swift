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

/// Which collection the shelf is showing, and what's being asked about one. Kept for as long as the
/// app runs, never saved, so the app always opens on All.
@MainActor
final class ShelfCollections: ObservableObject {
    /// The collection whose chip is on, or nil for All.
    @Published var activeID: UUID?
    @Published var sheet: CollectionSheet?
    /// A collection with books in it that's waiting on "Delete <Name>?".
    @Published var confirmingDelete: UUID?

    /// The collection showing, or nil for All, as it is when the one that was showing has gone.
    func active(in library: LibraryStore) -> BookCollection? {
        activeID.flatMap(library.collection(id:))
    }

    func showAll() {
        activeID = nil
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
    static func shelfOrder(_ library: LibraryStore, collection: UUID?) -> [String] {
        shown([library.current].compactMap { $0 } + library.others, in: collection).map(\.id)
    }

    /// The books in `collection`, in the order they came; all of them for nil.
    nonisolated static func shown(_ books: [Book], in collection: UUID?) -> [Book] {
        guard let collection else { return books }
        return books.filter { $0.collectionIDs.contains(collection) }
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
