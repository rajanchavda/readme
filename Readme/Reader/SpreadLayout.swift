import Foundation

enum SpreadLayout {
    /// Room foliate leaves around the text on each side.
    private static let margin = 48.0
    /// How wide a character is, as a share of the font size.
    private static let characterWidth = 0.42

    /// One or two pages across. Two only if each column holds enough characters at this size, and
    /// never when the book area is taller than wide, where foliate shows one column whatever is asked.
    /// A `windowHeight` of 0 means the height isn't known.
    static func columns(windowWidth: Double, fontSize: Double, lineWidth: LineWidth, windowHeight: Double = 0) -> Int {
        if windowHeight > windowWidth { return 1 }
        let column = (windowWidth - 2 * margin) / 2
        let characters = column / (fontSize * characterWidth)
        return characters >= minimumCharacters(lineWidth) ? 2 : 1
    }

    private static func minimumCharacters(_ lineWidth: LineWidth) -> Double {
        switch lineWidth {
        case .narrow: 40
        case .regular: 45
        case .wide: 52
        }
    }
}
