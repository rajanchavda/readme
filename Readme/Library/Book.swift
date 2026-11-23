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
    /// The collections it's in. Library files from before collections have none.
    var collectionIDs: [UUID] = []
}

extension Book {
    /// Written out by hand only so that a missing `collectionIDs` reads as none, as the synthesized
    /// decoder would refuse the whole library over it.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        fileName = try c.decode(String.self, forKey: .fileName)
        hasCover = try c.decode(Bool.self, forKey: .hasCover)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        lastReadAt = try c.decodeIfPresent(Date.self, forKey: .lastReadAt)
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle)
        chapterMinutesLeft = try c.decodeIfPresent(Double.self, forKey: .chapterMinutesLeft)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        collectionIDs = try c.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? []
    }
}
