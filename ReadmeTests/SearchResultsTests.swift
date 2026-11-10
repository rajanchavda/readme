import Testing
@testable import Readme

/// What the search box says about what was found.
@Suite struct SearchResultsTests {
    private func match(page: Int, chapter: String?) -> SearchMatch {
        SearchMatch(cfi: "epubcfi(/6/2!/4/2,/1:0,/1:5)", pre: "the girl ", match: "Elena", post: " stood", page: page,
                    chapter: chapter)
    }

    private func outcome(count: Int, capped: Bool = false) -> SearchOutcome {
        SearchOutcome(matches: Array(repeating: match(page: 1, chapter: nil), count: count), isCapped: capped)
    }

    @Test func searchableNeedsTwoCharacters() {
        #expect(!SearchResults.isSearchable(""))
        #expect(!SearchResults.isSearchable("e"))
        #expect(!SearchResults.isSearchable(" e "))
        #expect(SearchResults.isSearchable("el"))
    }

    @Test func countText() {
        #expect(SearchResults.countText(outcome(count: 0)) == "No matches")
        #expect(SearchResults.countText(outcome(count: 1)) == "1 match")
        #expect(SearchResults.countText(outcome(count: 84)) == "84 matches")
        #expect(SearchResults.countText(outcome(count: 500, capped: true))
            == "500+ matches, type more to narrow it down")
    }

    @Test func detailIsPageAndChapter() {
        #expect(SearchResults.detail(match(page: 142, chapter: "The Letter")) == "142 · The Letter")
        #expect(SearchResults.detail(match(page: 142, chapter: nil)) == "142")
        #expect(SearchResults.detail(match(page: 142, chapter: "  ")) == "142")
    }

    @Test func theLimitIsFiveHundred() {
        #expect(SearchResults.limit == 500)
        #expect(SearchResults.minimumLength == 2)
    }
}
