import Foundation
import Testing
@testable import Readme

private func book(
    title: String = "The Psychology of Money", author: String? = "Morgan Housel", progress: Double? = nil,
    chapter: String? = nil, minutes: Double? = nil, finished: Date? = nil, pinned: Bool = false
) -> Book {
    var b = Book(
        id: "a", title: title, author: author, fileName: "a.epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: 1), lastReadAt: nil, chapterTitle: chapter, chapterMinutesLeft: minutes)
    b.progress = progress
    b.finishedAt = finished
    b.pinnedAt = pinned ? Date(timeIntervalSince1970: 2) : nil
    return b
}

/// Noon UTC on that day, so the day is the same in any time zone the tests run in.
private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private let gb = Locale(identifier: "en_GB")

@Suite struct ReadingMarksTests {
    @Test func percentRoundsDown() {
        #expect(ReadingMarks.percent(0.999) == 99)
        #expect(ReadingMarks.percent(1) == 100)
        #expect(ReadingMarks.percent(0.42) == 42)
        #expect(ReadingMarks.percent(-0.1) == 0)
    }

    @Test func tooltipForAStartedBook() {
        let now = day(2026, 11, 23)
        #expect(ReadingMarks.tooltip(for: book(progress: 0.64, chapter: "Chapter 12"), now: now, locale: gb)
            == "The Psychology of Money — Morgan Housel\n64% · Chapter 12")
        #expect(ReadingMarks.tooltip(for: book(progress: 0.64), now: now, locale: gb)
            == "The Psychology of Money — Morgan Housel\n64%")
    }

    @Test func tooltipForAFinishedBook() {
        let now = day(2026, 11, 23)
        #expect(ReadingMarks.tooltip(for: book(progress: 1, chapter: "Notes", finished: day(2026, 11, 18)), now: now, locale: gb)
            == "The Psychology of Money — Morgan Housel\nFinished 18 Nov")
        #expect(ReadingMarks.tooltip(for: book(progress: 1, finished: day(2025, 11, 18)), now: now, locale: gb)
            == "The Psychology of Money — Morgan Housel\nFinished 18 Nov 2025")
    }

    @Test func tooltipForABookNeverOpened() {
        #expect(ReadingMarks.tooltip(for: book(), locale: gb) == "The Psychology of Money — Morgan Housel")
        #expect(ReadingMarks.tooltip(for: book(author: nil), locale: gb) == "The Psychology of Money")
    }

    @Test func accessibilityLabels() {
        #expect(ReadingMarks.accessibilityLabel(for: book(progress: 0.42)) == "The Psychology of Money, Morgan Housel, 42% read")
        #expect(ReadingMarks.accessibilityLabel(for: book(progress: 1, finished: day(2026, 1, 1), pinned: true))
            == "The Psychology of Money, Morgan Housel, pinned, finished")
        #expect(ReadingMarks.accessibilityLabel(for: book()) == "The Psychology of Money, Morgan Housel")
    }

    @Test func ledgeLine() {
        #expect(ReadingMarks.ledgeLine(for: book(progress: 0.42, chapter: "Chapter 7", minutes: 12)) == "42% · Chapter 7 · 12 min left")
        // The ticks on the cover already say it's done.
        #expect(ReadingMarks.ledgeLine(for: book(progress: 1, chapter: "Chapter 7", minutes: 12, finished: day(2026, 1, 1)))
            == "Chapter 7 · 12 min left")
        #expect(ReadingMarks.ledgeLine(for: book(chapter: "Chapter 7", minutes: 12)) == "Chapter 7 · 12 min left")
        #expect(ReadingMarks.ledgeLine(for: book(progress: 0.42)) == "42%")
        #expect(ReadingMarks.ledgeLine(for: book()) == nil)
    }
}
