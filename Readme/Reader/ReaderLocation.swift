import Foundation

/// Where the reader is in a book. `cfi` and `fraction` describe the start of the visible spread.
struct ReaderLocation: Codable, Sendable, Equatable {
    var cfi: String
    /// Progress through the book at the start of the visible spread, unlike foliate's own value,
    /// which is the end of it. It's 0 on the first page and stays below 1 on the last spread, so use
    /// `isAtEnd` to detect the end of the book.
    var fraction: Double
    var chapterTitle: String?
    var chapterMinutesLeft: Double
    var isAtStart: Bool
    var isAtEnd: Bool
}

/// One line of a book's table of contents. `level` is 0 at the top.
struct TOCEntry: Decodable, Sendable, Equatable {
    var title: String
    var href: String
    var level: Int
    /// Progress through the book at the start of the visible spread, unlike foliate's own value,
    /// which is the end of it. It's 0 on the first page and stays below 1 on the last spread, so use
    /// `isAtEnd` to detect the end of the book.
    var fraction: Double
}
