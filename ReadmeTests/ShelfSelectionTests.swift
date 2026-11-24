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

    @Test func pinMenuTitles() {
        #expect(ShelfSelection.pinMenuTitle(count: 1, allPinned: false) == "Pin to Front")
        #expect(ShelfSelection.pinMenuTitle(count: 3, allPinned: false) == "Pin 3 Books to Front")
        #expect(ShelfSelection.pinMenuTitle(count: 1, allPinned: true) == "Unpin")
        #expect(ShelfSelection.pinMenuTitle(count: 3, allPinned: true) == "Unpin 3 Books")
    }

    @Test func finishMenuTitles() {
        #expect(ShelfSelection.finishMenuTitle(count: 1, allFinished: false) == "Mark as Finished")
        #expect(ShelfSelection.finishMenuTitle(count: 3, allFinished: false) == "Mark 3 Books as Finished")
        #expect(ShelfSelection.finishMenuTitle(count: 1, allFinished: true) == "Mark as Not Finished")
        #expect(ShelfSelection.finishMenuTitle(count: 3, allFinished: true) == "Mark 3 Books as Not Finished")
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

    @Test func collectionCheckmark() {
        let x = UUID()
        func book(_ id: String, _ ids: [UUID]) -> Book {
            Book(
                id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false, addedAt: Date(),
                lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil, collectionIDs: ids)
        }
        #expect(ShelfSelection.isEveryBook([book("a", [x])], in: x))
        #expect(ShelfSelection.isEveryBook([book("a", [x]), book("b", [UUID(), x])], in: x))
        #expect(!ShelfSelection.isEveryBook([book("a", [x]), book("b", [])], in: x))
        #expect(!ShelfSelection.isEveryBook([], in: x))
        #expect(ShelfSelection.removeFromTitle(name: "Self-Help") == "Remove from Self-Help")
    }
}
