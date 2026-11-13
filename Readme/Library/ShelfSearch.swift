import Foundation

/// What's typed into the shelf's search field, whether the field is open, and which books it finds.
@MainActor
final class ShelfSearch: ObservableObject {
    @Published var query = ""
    @Published var isOpen = false
    /// Goes up each time the field is asked to take the keyboard.
    @Published private(set) var focusRequest = 0

    /// Whether anything is being looked for: spaces alone aren't.
    var isActive: Bool { !Self.words(query).isEmpty }

    /// Opens the field and puts the keyboard in it.
    func open() {
        isOpen = true
        focusRequest += 1
    }

    /// Empties the field and folds it back to its icon.
    func close() {
        query = ""
        isOpen = false
    }

    /// Whether every word typed is somewhere in the book's title or author, whatever the case and accents.
    nonisolated static func matches(_ book: Book, query: String) -> Bool {
        let words = words(query)
        guard !words.isEmpty else { return true }
        let text = fold(book.title + " " + (book.author ?? ""))
        return words.allSatisfy { text.contains($0) }
    }

    /// The books that match, in the order they came.
    nonisolated static func filter(_ books: [Book], query: String) -> [Book] {
        let words = words(query)
        guard !words.isEmpty else { return books }
        return books.filter { matches($0, query: query) }
    }

    private nonisolated static func words(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    private nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
