import Foundation

/// One place the searched words were found: where it is, the words around it, and the page and
/// chapter it's in. `page` is the page the match itself is on, so the spread it's on can start a
/// page or two before it.
struct SearchMatch: Codable, Equatable, Sendable {
    var cfi: String
    var pre: String
    var match: String
    var post: String
    var page: Int
    var chapter: String?
}

/// What a search found, in book order. `isCapped` says it stopped at the limit with more to find.
struct SearchOutcome: Equatable, Sendable {
    var matches: [SearchMatch]
    var isCapped: Bool
}
