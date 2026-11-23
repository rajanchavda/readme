import Foundation

/// A group of books the reader made, such as Self-Help or Investing. A book can be in any number of
/// them; which ones is kept on the book (`Book.collectionIDs`). Named so as not to clash with Swift's
/// `Collection`.
struct BookCollection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date

    static let maxNameLength = 40

    /// Offered under the name field, in this order, leaving out any that exist already.
    static let suggestedNames = [
        "Fiction", "Self-Help", "Business", "Investing", "Biography", "History", "Philosophy", "Spirituality", "Science",
    ]

    /// `raw` without spaces at either end and cut to `maxNameLength`, or nil if nothing is left.
    static func cleanName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name as it's compared: names that differ only in case or accents are the same name.
    static func key(_ name: String) -> String {
        ShelfSearch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func suggestions(excluding existing: [BookCollection]) -> [String] {
        let taken = Set(existing.map { key($0.name) })
        return suggestedNames.filter { !taken.contains(key($0)) }
    }
}
