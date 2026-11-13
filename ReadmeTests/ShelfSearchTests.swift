import Foundation
import Testing
@testable import Readme

private func book(_ id: String, _ title: String, by author: String? = nil) -> Book {
    Book(
        id: id, title: title, author: author, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: 0), lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

@Suite struct ShelfSearchTests {
    @Test func matchesTitleIgnoringCaseAndAccents() {
        let miserables = book("a", "Les Misérables")
        #expect(ShelfSearch.matches(miserables, query: "miserables"))
        #expect(ShelfSearch.matches(miserables, query: "MISÉR"))
        #expect(ShelfSearch.matches(miserables, query: "les mis"))
    }

    @Test func matchesAuthor() {
        #expect(ShelfSearch.matches(book("a", "Anna Karenina", by: "Leo Tolstoy"), query: "tolstoy"))
    }

    @Test func everyWordMustMatch() {
        let dune = book("a", "Dune", by: "Frank Herbert")
        #expect(ShelfSearch.matches(dune, query: "dune herbert"))
        #expect(!ShelfSearch.matches(dune, query: "dune asimov"))
    }

    @Test func noAuthorMatchesOnTitle() {
        let emma = book("a", "Emma")
        #expect(ShelfSearch.matches(emma, query: "emm"))
        #expect(!ShelfSearch.matches(emma, query: "austen"))
    }

    @Test func blankQueryMatchesEverything() {
        let books = [book("b", "Emma"), book("a", "Dune")]
        #expect(ShelfSearch.filter(books, query: "   ").map(\.id) == ["b", "a"])
    }

    @Test func filterKeepsOrder() {
        let books = [book("c", "Dune"), book("a", "Dune Messiah"), book("b", "Emma")]
        #expect(ShelfSearch.filter(books, query: "dune").map(\.id) == ["c", "a"])
    }

    @MainActor @Test func closeClearsAndFolds() {
        let search = ShelfSearch()
        search.open()
        #expect(search.isOpen)
        #expect(search.focusRequest == 1)
        search.query = "x"
        search.close()
        #expect(search.query == "")
        #expect(!search.isOpen)
    }

    @MainActor @Test func isActiveIgnoresWhitespace() {
        let search = ShelfSearch()
        search.query = "  "
        #expect(!search.isActive)
        search.query = " a "
        #expect(search.isActive)
    }
}
