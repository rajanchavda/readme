import Foundation

/// How wide the page's columns are and how many fit, in the numbers foliate lays out with.
enum SpreadLayout {
    /// foliate's #container is the view less a 3.5% gutter on each side.
    static let containerShare = 0.93
    /// foliate's column gap, as a share of the view (`--_gap: 7%`).
    static let gapShare = 0.07

    /// Width a character takes in a rendered line, as a share of the font size. Calibrated on the
    /// test book in the web view, so it covers spaces and the slack justified, hyphenated lines
    /// leave (`LineLengthTests` checks it). `ui-serif` is New York on macOS.
    static func characterWidth(_ font: BookFont) -> Double {
        switch font {
        case .ebGaramond: 0.365
        case .literata: 0.458
        case .newYork: 0.448
        }
    }

    /// The width a column should have for `lineWidth` characters a line at this size.
    static func columnWidth(fontSize: Double, font: BookFont, lineWidth: LineWidth) -> Double {
        lineWidth.characters * characterWidth(font) * fontSize
    }

    /// The width of a column when `columns` share a view this wide: foliate's container takes its
    /// share of the view, and the gaps between columns come out of that. Its gap is a share of the
    /// container, `gapShare / containerShare` of it, and the outer gutters are the rest.
    static func availableColumnWidth(windowWidth: Double, columns: Int) -> Double {
        let container = windowWidth * containerShare
        let gap = container * gapShare / containerShare
        return container / Double(columns) - gap
    }

    /// One or two pages across. Two only if each column could hold a full line of `lineWidth`
    /// characters at this size, and never when the book area is taller than wide, where
    /// foliate shows one column whatever is asked. A `windowHeight` of 0 means the height isn't known.
    static func columns(
        windowWidth: Double, fontSize: Double, lineWidth: LineWidth, windowHeight: Double = 0,
        font: BookFont = .ebGaramond
    ) -> Int {
        if windowHeight > windowWidth { return 1 }
        let wanted = columnWidth(fontSize: fontSize, font: font, lineWidth: lineWidth)
        return availableColumnWidth(windowWidth: windowWidth, columns: 2) >= wanted ? 2 : 1
    }
}
