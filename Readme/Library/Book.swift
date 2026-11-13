import Foundation

/// A book in the library. `id` is the SHA-256 of the file (see `BookID`), so the same book is the
/// same wherever it came from, and its saved place is found by it.
struct Book: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var author: String?
    /// The copy's name in the library's Books folder, which is `<id>.epub`, not what the file was called.
    var fileName: String
    var hasCover: Bool
    var addedAt: Date
    var lastReadAt: Date?
    /// Where the reader left off, as the shelf shows it.
    var chapterTitle: String?
    var chapterMinutesLeft: Double?
    /// When the reader pinned it to the front of the shelf, or nil if it isn't pinned.
    var pinnedAt: Date? = nil
}
