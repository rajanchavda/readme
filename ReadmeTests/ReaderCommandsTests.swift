import AppKit
import Testing
@testable import Readme

private func key(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }

@Suite struct ReaderCommandsTests {
    @Test func shortcuts() {
        #expect(ReaderCommand.biggerText.shortcut == KeyShortcut("+", [.command]))
        #expect(ReaderCommand.smallerText.shortcut == KeyShortcut("-", [.command]))
        #expect(ReaderCommand.toggleTOC.shortcut == KeyShortcut("t", [.command]))
        #expect(ReaderCommand.toggleFullscreen.shortcut == KeyShortcut("f", [.control, .command]))
        #expect(ReaderCommand.showLibrary.shortcut == KeyShortcut("l", [.command]))
        #expect(ReaderCommand.goToStart.shortcut == KeyShortcut(key(NSUpArrowFunctionKey), [.command]))
        #expect(ReaderCommand.goToEnd.shortcut == KeyShortcut(key(NSDownArrowFunctionKey), [.command]))
        #expect(ReaderCommand.goToPage.shortcut == KeyShortcut("g", [.command]))
        #expect(ReaderCommand.toggleMarker.shortcut == KeyShortcut("d", [.command]))
        #expect(ReaderCommand.goToMarker.shortcut == KeyShortcut("d", [.command, .shift]))
        #expect(ReaderCommand.find.shortcut == KeyShortcut("f", [.command]))
    }

    @Test func commandFFinds() {
        #expect(ReaderCommand(key: "f", modifiers: [.command]) == .find)
        #expect(ReaderCommand.find.title == "Find…")
    }

    @Test func noTwoCommandsShareAShortcut() {
        let shortcuts = ReaderCommand.allCases.map(\.shortcut)
        for (index, shortcut) in shortcuts.enumerated() {
            #expect(!shortcuts[(index + 1)...].contains(shortcut))
        }
    }

    @Test func eachShortcutMapsToItsCommand() {
        for command in ReaderCommand.allCases {
            #expect(ReaderCommand(key: command.shortcut.key, modifiers: command.shortcut.modifiers) == command)
        }
    }

    /// Arrow keys carry the function and numeric pad flags, which aren't part of a shortcut.
    @Test func deviceFlagsAreIgnored() {
        #expect(ReaderCommand(key: key(NSUpArrowFunctionKey), modifiers: [.command, .function, .numericPad]) == .goToStart)
    }

    /// ⌘+ is typed as ⌘= on most layouts, and as ⌘⇧= by those who think of the plus.
    @Test func biggerTextWithOrWithoutShift() {
        #expect(ReaderCommand(key: "=", modifiers: [.command]) == .biggerText)
        #expect(ReaderCommand(key: "+", modifiers: [.command, .shift]) == .biggerText)
    }

    @Test func homeAndEnd() {
        #expect(ReaderCommand(key: key(NSHomeFunctionKey), modifiers: []) == .goToStart)
        #expect(ReaderCommand(key: key(NSEndFunctionKey), modifiers: []) == .goToEnd)
        #expect(ReaderCommand(key: key(NSHomeFunctionKey), modifiers: [.function]) == .goToStart)
    }

    @Test func plainFTogglesFullscreen() {
        #expect(ReaderCommand(key: "f", modifiers: []) == .toggleFullscreen)
        #expect(ReaderCommand(key: "f", modifiers: [.option]) == nil)
    }

    /// Turning pages is not a command, and nor is anything else typed.
    @Test func otherKeysAreNotCommands() {
        #expect(ReaderCommand(key: key(NSRightArrowFunctionKey), modifiers: []) == nil)
        #expect(ReaderCommand(key: " ", modifiers: []) == nil)
        #expect(ReaderCommand(key: "t", modifiers: []) == nil)
        #expect(ReaderCommand(key: "x", modifiers: [.command]) == nil)
    }

    @Test func fontSizeLimits() {
        var size = 18.0
        for _ in 0..<40 { size = ReaderCommand.fontSize(after: .biggerText, from: size) }
        #expect(size == 40)
        for _ in 0..<40 { size = ReaderCommand.fontSize(after: .smallerText, from: size) }
        #expect(size == 12)
        #expect(ReaderCommand.fontSize(after: .biggerText, from: 18) > 18)
        #expect(ReaderCommand.fontSize(after: .smallerText, from: 18) < 18)
        #expect(ReaderCommand.fontSize(after: .biggerText, from: 90) == 40)
        #expect(ReaderCommand.fontSize(after: .smallerText, from: 3) == 12)
        #expect(ReaderCommand.fontSize(after: .toggleTOC, from: 18) == 18)
    }
}
