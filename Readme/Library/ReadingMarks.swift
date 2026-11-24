import SwiftUI

/// What the shelf says about how far through a book the reader is: the words for its tooltip, its
/// VoiceOver label and the ledge, and the bar and ticks drawn with its cover.
enum ReadingMarks {
    /// How far through, in whole percent, rounded down so a book is never 100% until it's at the end.
    nonisolated static func percent(_ progress: Double) -> Int {
        min(100, max(0, Int((progress * 100).rounded(.down))))
    }

    /// The cover's tooltip: "Title — Author", then where the reader is, or when it was finished. A
    /// book never opened has the first line only.
    nonisolated static func tooltip(for book: Book, now: Date = Date(), locale: Locale = .current) -> String {
        let name = [book.title, book.author].compactMap { $0 }.joined(separator: " — ")
        let place: String?
        if let finishedAt = book.finishedAt {
            place = "Finished " + finishedDate(finishedAt, now: now, locale: locale)
        } else if let progress = book.progress {
            place = (["\(percent(progress))%"] + [book.chapterTitle].compactMap { $0?.isEmpty == false ? $0 : nil })
                .joined(separator: " · ")
        } else {
            place = nil
        }
        return ([name] + [place].compactMap { $0 }).joined(separator: "\n")
    }

    /// "18 Nov", with the year when it isn't this one.
    nonisolated static func finishedDate(_ date: Date, now: Date, locale: Locale) -> String {
        let calendar = Calendar.current
        var style = Date.FormatStyle().locale(locale).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// "Title, Author, pinned, 42% read", or ", finished", with whichever parts apply.
    nonisolated static func accessibilityLabel(for book: Book) -> String {
        var parts = [book.title, book.author].compactMap { $0 }
        if book.pinnedAt != nil { parts.append("pinned") }
        if book.isFinished {
            parts.append("finished")
        } else if let progress = book.progress {
            parts.append("\(percent(progress))% read")
        }
        return parts.joined(separator: ", ")
    }

    /// The ledge's line: "42% · Chapter 7 · 12 min left". A finished book leaves out the percentage,
    /// as its ticks say so.
    nonisolated static func ledgeLine(for book: Book) -> String? {
        let percentage = book.isFinished ? nil : book.progress.map { "\(percent($0))%" }
        let parts = [percentage, CurrentBookShelf.progressLine(for: book)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A thin bar under a cover showing how far through the book the reader is, in the marker's colour.
struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ShelfStyle.text.opacity(0.10))
                Capsule()
                    .fill(PinRibbon.color.opacity(0.85))
                    .frame(width: geometry.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: ProgressBar.height)
        .accessibilityHidden(true)
    }

    static let height: CGFloat = 3
    /// From the cover's bottom edge to the bar.
    static let gap: CGFloat = 7
}

/// Two ticks, as a message shows once it's read, in an 18 × 14 box.
struct DoubleTick: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 18, sy = rect.height / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(1.5, 7.4))
        path.addLine(to: p(4.5, 10.4))
        path.addLine(to: p(10.5, 3.8))
        path.move(to: p(8.6, 10.1))
        path.addLine(to: p(8.9, 10.4))
        path.addLine(to: p(14.9, 3.8))
        return path
    }
}

/// The mark of a finished book: white ticks in the cover's bottom-right corner, on a small shade that
/// fades out from the corner so they read on pale covers and dark ones alike.
struct FinishedTicks: View {
    let width: CGFloat

    var body: some View {
        let scale = width / 112
        ZStack(alignment: .bottomTrailing) {
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.4),
                    .init(color: .clear, location: 0.72),
                ],
                center: .bottomTrailing, startRadiusFraction: 0, endRadiusFraction: 1.41)
                .frame(width: 34 * scale, height: 30 * scale)
            DoubleTick()
                .stroke(.white, style: StrokeStyle(lineWidth: 1.7 * scale, lineCap: .round, lineJoin: .round))
                .frame(width: 18 * scale, height: 14 * scale)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                .padding(5 * scale)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
