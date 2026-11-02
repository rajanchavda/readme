import Foundation

/// How far the reader has got with one entry of the contents.
enum TOCState: Equatable {
    case read, current, unread
}

/// Which entries of the contents have been read, which is being read and which are still ahead, for
/// the sidebar to dim the ones behind.
enum TOCProgress {
    /// A spread that starts where a chapter does can be reported a hair before it.
    private static let tolerance = 1e-9

    /// `fraction` is where the visible spread starts. The current entry is the last one, in the
    /// contents' order, that starts there or before. Before the first entry nothing is current.
    static func states(entries: [TOCEntry], fraction: Double) -> [TOCState] {
        guard let current = entries.lastIndex(where: { $0.fraction <= fraction + tolerance }) else {
            return entries.map { _ in .unread }
        }
        return entries.indices.map { index in
            index < current ? .read : index == current ? .current : .unread
        }
    }
}
