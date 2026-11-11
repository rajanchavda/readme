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

/// What the search box says about a search.
enum SearchResults {
    /// Fewer characters than this search nothing, as one letter is on nearly every page.
    static let minimumLength = 2
    /// The most matches listed. Past this, the reader types more to narrow it down.
    static let limit = 500

    static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength
    }

    static func countText(_ outcome: SearchOutcome) -> String {
        let count = outcome.matches.count
        if outcome.isCapped { return "\(count.formatted())+ matches, type more to narrow it down" }
        switch count {
        case 0: return "No matches"
        case 1: return "1 match"
        default: return "\(count.formatted()) matches"
        }
    }

    /// The page and chapter, as a row shows them beside the match.
    static func detail(_ match: SearchMatch) -> String {
        guard let chapter = match.chapter?.trimmingCharacters(in: .whitespacesAndNewlines), !chapter.isEmpty
        else { return String(match.page) }
        return "\(match.page) · \(chapter)"
    }
}
