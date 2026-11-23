import Foundation

/// When reading finishes a book: turning pages across 95%, or onto the last spread. Most books end
/// in notes and an index nobody reads, so the very last page would leave most of them unfinished.
/// Jumps never count, and nor does turning on from above the line, so a book marked as not finished
/// at 97% isn't finished again by the next page.
enum FinishRule {
    static let threshold = 0.95

    /// Whether moving from `previous` to `location` finishes the book. `byTurning` is false for any
    /// jump: the contents, Go to Page, the End key, a link, the marker, a search result.
    nonisolated static func finishes(from previous: ReaderLocation?, to location: ReaderLocation, byTurning: Bool) -> Bool {
        guard byTurning, let previous else { return false }
        let crossesLine = previous.fraction < threshold && !previous.isAtEnd
            && (location.fraction >= threshold || location.isAtEnd)
        let reachesEnd = !previous.isAtEnd && location.isAtEnd
        return crossesLine || reachesEnd
    }
}
