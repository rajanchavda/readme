import Testing
@testable import Readme

/// How far through each chapter of the contents the reader is.
@Suite struct TOCProgressTests {
    private func entries(_ fractions: [Double]) -> [TOCEntry] {
        fractions.enumerated().map { TOCEntry(title: "Chapter \($0.offset + 1)", href: "ch\($0.offset + 1).xhtml", level: 0, fraction: $0.element) }
    }

    @Test func chaptersBeforeTheCurrentOneAreRead() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0.6) == [.read, .current, .unread])
    }

    @Test func theFirstChapterIsCurrentAtTheStart() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0) == [.current, .unread, .unread])
    }

    @Test func noEntriesHaveNoStates() {
        #expect(TOCProgress.states(entries: [], fraction: 0.4).isEmpty)
    }

    /// A spread starting where a chapter does can be reported a hair before it.
    @Test func aChapterStartingWhereTheSpreadDoesIsCurrent() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 0.5 - 1e-12) == [.read, .current, .unread])
    }

    @Test func theLastChapterIsCurrentAtTheEnd() {
        #expect(TOCProgress.states(entries: entries([0, 0.5, 0.8]), fraction: 1) == [.read, .read, .current])
    }

    /// Before the first entry, on a cover, say, nothing has been read yet.
    @Test func beforeTheFirstEntryNothingIsCurrent() {
        #expect(TOCProgress.states(entries: entries([0.1, 0.5]), fraction: 0.02) == [.unread, .unread])
    }
}
