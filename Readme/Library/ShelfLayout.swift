import CoreGraphics
import Foundation

/// How the shelves are laid out: how many books a row holds, and how many empty shelves fill the window.
enum ShelfLayout {
    /// A shelf's height, and its gap to the next, as in the mockup.
    static let shelfHeight: CGFloat = 210
    static let shelfGap: CGFloat = 24
    /// The top shelf, which holds the current book.
    static let ledgeHeight: CGFloat = 262

    /// `items` in rows that fit `width`, in order. A row holds at least one, however narrow the window.
    static func rows<T>(
        _ items: [T], width: CGFloat, coverWidth: CGFloat = 112, gap: CGFloat = 22, inset: CGFloat = 54
    ) -> [[T]] {
        let perRow = booksPerRow(width: width, coverWidth: coverWidth, gap: gap, inset: inset)
        return stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
    }

    static func booksPerRow(width: CGFloat, coverWidth: CGFloat = 112, gap: CGFloat = 22, inset: CGFloat = 54) -> Int {
        let usable = width - 2 * inset
        let fits = ((usable + gap) / (coverWidth + gap)).rounded(.down)
        return fits.isFinite ? max(1, Int(fits)) : 1
    }

    /// The shelves below the top one that fill a window `height` tall, and never fewer than one.
    static func emptyRowCount(height: CGFloat) -> Int {
        let below = height - ledgeHeight - shelfGap
        guard below.isFinite else { return 1 }
        return max(1, Int((below / (shelfHeight + shelfGap)).rounded(.up)))
    }
}
