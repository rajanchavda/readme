import AppKit

/// What the shortcuts panel lists: every reader command, and the keys that aren't commands, in
/// groups, each with the keys that do it and a few words on what it does.
enum ShortcutsHelp {
    struct Row: Equatable {
        /// Each is one way to do it, such as "⌘↑" or "Home".
        let keys: [String]
        let description: String
    }

    struct Section: Equatable {
        let title: String
        let rows: [Row]
    }

    /// The panel's two columns, left then right.
    static let columns: [[Section]] = [
        [
            Section(title: "Reading", rows: [
                Row(keys: ["→", "Space"], description: "Next page"),
                Row(keys: ["←"], description: "Previous page"),
                row(.biggerText),
                row(.smallerText),
            ]),
            Section(title: "Moving Around", rows: [
                row(.goToStart),
                row(.goToEnd),
                row(.goToPage),
                row(.find),
                row(.toggleMarker),
                row(.goToMarker),
            ]),
        ],
        [
            Section(title: "Panels", rows: [
                row(.toggleTOC),
                row(.toggleHighlights),
                row(.showLibrary),
                Row(keys: ["⌘O"], description: "Open a book"),
            ]),
            Section(title: "Window", rows: [
                row(.toggleFullscreen),
                Row(keys: ["Esc"], description: "Close a panel or leave full screen"),
                row(.showShortcuts),
            ]),
        ],
    ]

    static var sections: [Section] { columns.flatMap { $0 } }

    /// A command's row: its shortcut, then any plain key that stands in for it.
    static func row(_ command: ReaderCommand) -> Row {
        Row(keys: [symbols(command.shortcut)] + plainKeys(command), description: description(command))
    }

    static func description(_ command: ReaderCommand) -> String {
        switch command {
        case .biggerText: "Bigger text"
        case .smallerText: "Smaller text"
        case .toggleTOC: "Show or hide the contents"
        case .toggleHighlights: "Show or hide your highlights"
        case .toggleMarker: "Mark or unmark this page"
        case .toggleFullscreen: "Full screen"
        case .showLibrary: "Show the library"
        case .goToStart: "Go to the start"
        case .goToEnd: "Go to the end"
        case .goToPage: "Go to a page number"
        case .goToMarker: "Go to the marked page"
        case .find: "Find in the book"
        case .showShortcuts: "Show these shortcuts"
        }
    }

    /// The keys without modifiers that `ReaderCommand(key:modifiers:)` takes for the command.
    static func plainKeys(_ command: ReaderCommand) -> [String] {
        switch command {
        case .goToStart: ["Home"]
        case .goToEnd: ["End"]
        case .toggleFullscreen: ["F"]
        case .showShortcuts: ["?"]
        default: []
        }
    }

    /// How a Mac menu writes a shortcut: the modifiers in their usual order, then the key.
    static func symbols(_ shortcut: KeyShortcut) -> String {
        var text = ""
        if shortcut.modifiers.contains(.control) { text += "⌃" }
        if shortcut.modifiers.contains(.option) { text += "⌥" }
        if shortcut.modifiers.contains(.shift) { text += "⇧" }
        if shortcut.modifiers.contains(.command) { text += "⌘" }
        return text + keyName(shortcut.key)
    }

    private static func keyName(_ key: String) -> String {
        switch key {
        case KeyShortcut.character(NSUpArrowFunctionKey): "↑"
        case KeyShortcut.character(NSDownArrowFunctionKey): "↓"
        case KeyShortcut.character(NSLeftArrowFunctionKey): "←"
        case KeyShortcut.character(NSRightArrowFunctionKey): "→"
        case KeyShortcut.character(NSHomeFunctionKey): "Home"
        case KeyShortcut.character(NSEndFunctionKey): "End"
        case "-": "−"
        case " ": "Space"
        default: key.uppercased()
        }
    }
}
