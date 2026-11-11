import AppKit
import Testing
@testable import Readme

@MainActor
@Suite struct ShelfSelectionTests {
    let order = ["a", "b", "c", "d"]

    @Test func plainClickOpensAndClears() {
        let selection = ShelfSelection()
        _ = selection.click("a", modifiers: .command, order: order)
        #expect(selection.click("b", modifiers: [], order: order) == .open)
        #expect(selection.ids.isEmpty)
    }

    @Test func commandClickToggles() {
        let selection = ShelfSelection()
        #expect(selection.click("a", modifiers: .command, order: order) == .changed)
        #expect(selection.click("c", modifiers: .command, order: order) == .changed)
        #expect(selection.ids == ["a", "c"])
        #expect(selection.click("a", modifiers: .command, order: order) == .changed)
        #expect(selection.ids == ["c"])
    }

    @Test func shiftClickSelectsTheRun() {
        let selection = ShelfSelection()
        _ = selection.click("b", modifiers: .command, order: order)
        #expect(selection.click("d", modifiers: .shift, order: order) == .changed)
        #expect(selection.ids == ["b", "c", "d"])
        _ = selection.click("a", modifiers: .shift, order: order)
        #expect(selection.ids == ["a", "b"])
    }

    @Test func shiftClickWithoutAnchorSelectsOne() {
        let selection = ShelfSelection()
        #expect(selection.click("c", modifiers: .shift, order: order) == .changed)
        #expect(selection.ids == ["c"])
    }

    @Test func targetsFollowTheSelection() {
        let selection = ShelfSelection()
        _ = selection.click("c", modifiers: .command, order: order)
        _ = selection.click("a", modifiers: .command, order: order)
        #expect(selection.targets(rightClicked: "a", order: order) == ["a", "c"])
        #expect(selection.targets(rightClicked: "b", order: order) == ["b"])
        #expect(selection.menuTitle(rightClicked: "a") == "Export 2 Books…")
        #expect(selection.menuTitle(rightClicked: "b") == "Export…")
    }

    @Test func clearEmptiesIt() {
        let selection = ShelfSelection()
        _ = selection.click("c", modifiers: .command, order: order)
        selection.clear()
        #expect(selection.ids.isEmpty)
        // The anchor goes too, so a shift-click starts afresh.
        _ = selection.click("a", modifiers: .shift, order: order)
        #expect(selection.ids == ["a"])
    }
}
