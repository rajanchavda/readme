import AppKit

/// A key and the modifiers held with it. `key` is what `charactersIgnoringModifiers` gives, so an
/// arrow or Home is its function-key character.
struct KeyShortcut: Equatable {
    var key: String
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Only these take part in a shortcut. Arrows and Home also carry `.function` and `.numericPad`.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    static func character(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }
}

/// What the reader can ask of the window, besides turning pages. Each has a menu item and a key.
enum ReaderCommand: CaseIterable {
    case biggerText, smallerText, toggleTOC, toggleFullscreen, showLibrary, goToStart, goToEnd, goToPage

    static let fontSizes = 12.0...40.0
    static let fontSizeStep = 2.0

    var shortcut: KeyShortcut {
        switch self {
        case .biggerText: KeyShortcut("+", [.command])
        case .smallerText: KeyShortcut("-", [.command])
        case .toggleTOC: KeyShortcut("t", [.command])
        case .toggleFullscreen: KeyShortcut("f", [.control, .command])
        case .showLibrary: KeyShortcut("l", [.command])
        case .goToStart: KeyShortcut(KeyShortcut.character(NSUpArrowFunctionKey), [.command])
        case .goToEnd: KeyShortcut(KeyShortcut.character(NSDownArrowFunctionKey), [.command])
        case .goToPage: KeyShortcut("g", [.command])
        }
    }

    var title: String {
        switch self {
        case .biggerText: "Bigger Text"
        case .smallerText: "Smaller Text"
        case .toggleTOC: "Contents"
        case .toggleFullscreen: "Toggle Full Screen"
        case .showLibrary: "Library"
        case .goToStart: "Go to Start"
        case .goToEnd: "Go to End"
        case .goToPage: "Go to Page…"
        }
    }

    /// The command a key press asks for, if any: a shortcut, or one of the plain keys that stand in
    /// for one. Home and End go to the start and end, and F toggles fullscreen.
    init?(key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers = modifiers.intersection(KeyShortcut.relevantModifiers)
        var key = key
        // ⌘+ is ⌘= on most layouts, or ⌘⇧= typed as the plus.
        if modifiers.contains(.command), key == "=" || key == "+" {
            key = "+"
            modifiers.remove(.shift)
        }
        if let command = Self.allCases.first(where: { $0.shortcut == KeyShortcut(key, modifiers) }) {
            self = command
            return
        }
        guard modifiers.isEmpty else { return nil }
        switch key {
        case KeyShortcut.character(NSHomeFunctionKey): self = .goToStart
        case KeyShortcut.character(NSEndFunctionKey): self = .goToEnd
        case "f", "F": self = .toggleFullscreen
        default: return nil
        }
    }

    /// The font size after this command, which only the text size commands change. It stays within
    /// `fontSizes`.
    static func fontSize(after command: ReaderCommand, from size: Double) -> Double {
        let changed = switch command {
        case .biggerText: size + fontSizeStep
        case .smallerText: size - fontSizeStep
        default: size
        }
        return min(fontSizes.upperBound, max(fontSizes.lowerBound, changed))
    }
}
