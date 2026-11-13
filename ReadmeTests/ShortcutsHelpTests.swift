import AppKit
import Testing
@testable import Readme

private func key(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }

@Suite struct ShortcutsHelpTests {
    /// A new command can't be left out of the panel, or shown twice.
    @Test func everyCommandIsListedOnce() {
        let rows = ShortcutsHelp.sections.flatMap(\.rows)
        for command in ReaderCommand.allCases {
            #expect(rows.filter { $0 == ShortcutsHelp.row(command) }.count == 1, "\(command)")
        }
    }

    /// The plain keys listed are ones the reader takes for the command.
    @Test func plainKeysDoTheirCommand() throws {
        let typed = ["Home": key(NSHomeFunctionKey), "End": key(NSEndFunctionKey), "F": "f", "?": "?"]
        for command in ReaderCommand.allCases {
            for name in ShortcutsHelp.plainKeys(command) {
                let character = try #require(typed[name])
                #expect(ReaderCommand(key: character, modifiers: []) == command, "\(name)")
            }
        }
    }

    @Test func symbolsAreWrittenAsInMenus() {
        #expect(ShortcutsHelp.symbols(KeyShortcut("t", [.command])) == "⌘T")
        #expect(ShortcutsHelp.symbols(KeyShortcut("d", [.command, .shift])) == "⇧⌘D")
        #expect(ShortcutsHelp.symbols(KeyShortcut("f", [.control, .command])) == "⌃⌘F")
        #expect(ShortcutsHelp.symbols(KeyShortcut(key(NSUpArrowFunctionKey), [.command])) == "⌘↑")
        #expect(ShortcutsHelp.symbols(KeyShortcut("-", [.command])) == "⌘−")
        #expect(ShortcutsHelp.symbols(KeyShortcut("/", [.command])) == "⌘/")
    }

    @Test func rowsShowEveryWayToDoIt() {
        #expect(ShortcutsHelp.row(.goToStart).keys == ["⌘↑", "Home"])
        #expect(ShortcutsHelp.row(.toggleFullscreen).keys == ["⌃⌘F", "F"])
        #expect(ShortcutsHelp.row(.showShortcuts).keys == ["⌘/", "?"])
        #expect(ShortcutsHelp.row(.find).keys == ["⌘F"])
    }

    @MainActor @Test func panelShowsEveryRowsKeys() {
        let panel = ShortcutsPanel(frame: NSRect(x: 0, y: 0, width: ShortcutsPanel.width, height: 400))
        #expect(panel.shownKeys == ShortcutsHelp.sections.flatMap(\.rows).map(\.keys))
    }

    @Test func libraryKeysAreListed() throws {
        let library = try #require(ShortcutsHelp.sections.first { $0.title == "Library" })
        #expect(library.rows == [
            ShortcutsHelp.Row(keys: ["⌘F"], description: "Search the library"),
            ShortcutsHelp.Row(keys: ["Esc"], description: "Clear the search"),
        ])
    }
}
