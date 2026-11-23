import Foundation
import Testing
@testable import Readme

@Suite struct CollectionNameSheetTests {
    @Test func addsLine() {
        #expect(CollectionNameSheet.addsLine(count: 0) == nil)
        #expect(CollectionNameSheet.addsLine(count: 1) == "Adds this book.")
        #expect(CollectionNameSheet.addsLine(count: 2) == "Adds the 2 selected books.")
    }

    @Test func renameConflict() {
        let fiction = BookCollection(id: UUID(), name: "Fiction", createdAt: Date())
        let history = BookCollection(id: UUID(), name: "History", createdAt: Date())
        let all = [fiction, history]
        #expect(CollectionNameSheet.renameConflict("fiction", renaming: history.id, in: all)
            == "There\u{2019}s already a collection called Fiction.")
        #expect(CollectionNameSheet.renameConflict("FICTION", renaming: fiction.id, in: all) == nil)
        #expect(CollectionNameSheet.renameConflict("Travel", renaming: history.id, in: all) == nil)
    }
}
