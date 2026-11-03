import Foundation

/// Where the app opens: straight into the book last read, at its place, or the library when no book
/// has been read yet or the last one's file has gone.
enum LaunchRoute: Equatable {
    case library
    case read(Book, cfi: String?)

    /// `positions` are the saved places by book ID. A book that was read but whose place was never
    /// kept opens at its start.
    @MainActor
    static func resolve(
        library: LibraryStore, positions: [String: ReaderLocation], fileExists: (URL) -> Bool
    ) -> LaunchRoute {
        guard let book = library.current, book.lastReadAt != nil, fileExists(library.fileURL(for: book))
        else { return .library }
        return .read(book, cfi: positions[book.id]?.cfi)
    }
}
