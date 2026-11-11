import SwiftUI

/// The top shelf: the current book with its title, author and where the reader left off, or on first
/// open, a place to drop a first book.
struct CurrentBookShelf: View {
    let book: Book?
    let library: LibraryStore
    let onOpen: (Book) -> Void
    let onRemove: (Book) -> Void
    let selection: ShelfSelection
    let onExport: ([Book]) -> Void

    var body: some View {
        ShelfRow(height: ShelfLayout.ledgeHeight, gap: 28) {
            if let book {
                ShelfBook(
                    book: book, width: 150, library: library, extraShadow: true, selection: selection,
                    onOpen: onOpen, onRemove: onRemove, onExport: onExport)
                    .id(book.id)
                    .transition(.opacity)
                info(book)
                    .id(book.id)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(ShelfStyle.text.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 150, height: 225)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Drop a book here")
                        .font(ShelfStyle.title(34))
                        .foregroundStyle(ShelfStyle.text)
                    Text("Any EPUB file will do.")
                        .font(ShelfStyle.body(17, italic: true))
                        .foregroundStyle(ShelfStyle.soft)
                }
                .padding(.bottom, 20)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func info(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONTINUE READING")
                .font(ShelfStyle.body(12))
                .tracking(2.16)
                .foregroundStyle(ShelfStyle.muted)
            Text(book.title)
                .font(ShelfStyle.title(34))
                .foregroundStyle(ShelfStyle.text)
                .lineLimit(2)
                .padding(.top, 6)
                .padding(.bottom, 4)
            if let author = book.author {
                Text(author)
                    .font(ShelfStyle.body(17, italic: true))
                    .foregroundStyle(ShelfStyle.soft)
                    .lineLimit(1)
            }
            if let line = Self.progressLine(for: book) {
                Text(line)
                    .font(ShelfStyle.body(15))
                    .foregroundStyle(ShelfStyle.soft)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
        }
        .padding(.bottom, 20)
        .accessibilityElement(children: .combine)
    }

    /// "Chapter 1, Loomings · 23 min left", with whichever of the two parts the book has. Nil if neither.
    static func progressLine(for book: Book) -> String? {
        let parts = [book.chapterTitle.flatMap { $0.isEmpty ? nil : $0 }, book.chapterMinutesLeft.map(timeLeft)]
        let line = parts.compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    static func timeLeft(_ minutes: Double) -> String {
        let total = max(1, Int(minutes.rounded(.up)))
        if total < 60 { return "\(total) min left" }
        let (hours, rest) = total.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }
}
