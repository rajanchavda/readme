import Foundation

/// What the shelf shows: every book, the ones being read, the ones finished, or one collection.
enum ShelfFilter: Hashable, Sendable {
    case all
    /// Opened and not finished.
    case reading
    case finished
    case collection(UUID)
}
