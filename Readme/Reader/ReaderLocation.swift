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
    /// The page the spread starts on, from 1, and how many the book has. A page is a fixed run of
    /// text, foliate's location, so it stays the same when the font or window changes. It isn't the
    /// page printed in a paper edition.
    var page: Int
    var pageCount: Int
}

/// One line of a book's table of contents. `level` is 0 at the top.
struct TOCEntry: Decodable, Sendable, Equatable {
    var title: String
    var href: String
    var level: Int
    /// Roughly where this entry starts in the book, for `BookWebView.go(toFraction:)`. An entry with a
    /// fragment is placed by the share of its section's text that comes before the fragment. Nil for a
    /// link that leads nowhere in the book.
    var fraction: Double?
}
