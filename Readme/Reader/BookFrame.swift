import Foundation

/// Where the book lies on the desk, and how it's laid out there, as in `docs/mockups/open-book-v2.html`:
/// a margin of desk all round, two pages up to a width, and one narrower page when two readable pages
/// won't fit.
struct BookFrame: Equatable {
    var frame: CGRect
    var columns: Int
    /// The width each column should have, for `BookWebView.applyStyles`.
    var columnWidth: Double
    /// The font size the text is set at, fullscreen's larger one included.
    var fontSize: Double

    /// Room for the page to overflow the book as it lifts towards the reader.
    static let margin: CGFloat = 34
    /// Fullscreen's margin, as a share of the screen's width and height.
    static let fullscreenMarginShare: CGFloat = 0.03
    static let spreadWidth: CGFloat = 980
    static let fullscreenSpreadWidth: CGFloat = 1500
    static let pageWidth: CGFloat = 560

    init(in size: CGSize, settings: ReaderSettings, fullscreen: Bool) {
        let scale = fullscreen ? ReadingCSS.fullscreenScale : 1
        fontSize = settings.fontSize * scale
        columnWidth = SpreadLayout.columnWidth(fontSize: fontSize, font: settings.font, lineWidth: settings.lineWidth)
        let area = fullscreen
            ? CGRect(origin: .zero, size: size).insetBy(
                dx: size.width * Self.fullscreenMarginShare, dy: size.height * Self.fullscreenMarginShare)
            : CGRect(origin: .zero, size: size).insetBy(dx: Self.margin, dy: Self.margin)
        let available = max(0, area.width.rounded(.down))

        // Wider than usual if the text is large enough to need it for two pages, so a big enough
        // window always shows two.
        let spread = min(available, max(
            fullscreen ? Self.fullscreenSpreadWidth : Self.spreadWidth, Self.width(holding: columnWidth, columns: 2)))
        columns = SpreadLayout.columns(
            windowWidth: spread, fontSize: fontSize, lineWidth: settings.lineWidth,
            windowHeight: area.height, font: settings.font)
        let width = columns == 2
            ? spread
            : min(available, max((Self.pageWidth * scale).rounded(), Self.width(holding: columnWidth, columns: 1)))
        frame = CGRect(
            x: (area.minX + (area.width - width) / 2).rounded(), y: area.minY.rounded(),
            width: width, height: max(0, area.height.rounded(.down)))
    }

    /// The narrowest book whose columns are each `columnWidth` wide, rounded up a point so foliate's
    /// sums can't fall short of it.
    private static func width(holding columnWidth: Double, columns: Int) -> CGFloat {
        CGFloat((columnWidth / SpreadLayout.availableColumnWidth(windowWidth: 1, columns: columns)).rounded(.up) + 1)
    }
}
