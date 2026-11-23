import CoreGraphics

/// Which chips are on the row and which are in its More menu, by their place in the row: All at 0,
/// then the collections.
struct ChipFit: Equatable {
    var visible: [Int]
    var overflow: [Int]
}

/// How the chip row shares the search's line: as many chips as fit, then a More chip for the rest,
/// and + always after them.
enum ChipRowLayout {
    static let gap: CGFloat = 8
    /// Where the row starts, clear of the window's buttons.
    static let leading: CGFloat = 88
    /// Between the row's end and the search.
    static let searchGap: CGFloat = 16

    /// The chips that fit in `available`, given each one's width, with room kept for + (`addWidth`)
    /// and, when some don't fit, the More chip (`moreWidth`). All always stays, and the active chip is
    /// swapped in for the last one that fits when it doesn't fit itself.
    static func fit(widths: [CGFloat], active: Int, available: CGFloat, moreWidth: CGFloat, addWidth: CGFloat) -> ChipFit {
        let all = Array(widths.indices)
        let whole = widths.reduce(0) { $0 + $1 + gap } + addWidth
        if whole <= available { return ChipFit(visible: all, overflow: []) }

        let budget = available - addWidth - moreWidth - 2 * gap
        var visible: [Int] = []
        var used: CGFloat = 0
        for index in all {
            let width = widths[index] + gap
            if index > 0 && used + width > budget { break }
            visible.append(index)
            used += width
        }
        if !visible.contains(active), visible.count > 1 {
            visible[visible.count - 1] = active
        }
        return ChipFit(visible: visible, overflow: all.filter { !visible.contains($0) })
    }
}
