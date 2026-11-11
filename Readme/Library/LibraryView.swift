import SwiftUI

/// The bookshelf: the current book on its own shelf, the rest below, and a drop target for new ones.
struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    let importer: BookImporter
    let onOpen: (Book) -> Void
    /// The books picked out on the shelf, and what exporting them does.
    @ObservedObject var selection: ShelfSelection
    let onExport: ([Book]) -> Void

    @StateObject private var drops: ShelfDrops
    @State private var targeted = false
    @State private var scrollerWidth = Self.reservedScrollerWidth()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(library: LibraryStore, importer: BookImporter, onOpen: @escaping (Book) -> Void) {
        self.init(library: library, importer: importer, onOpen: onOpen, previewing: [])
    }

    /// With notices the app can add to, as it does when a book on the shelf won't open.
    init(
        library: LibraryStore, importer: BookImporter, drops: ShelfDrops, selection: ShelfSelection = ShelfSelection(),
        onOpen: @escaping (Book) -> Void, onExport: @escaping ([Book]) -> Void = { _ in }
    ) {
        self.library = library
        self.importer = importer
        self.onOpen = onOpen
        self.selection = selection
        self.onExport = onExport
        _drops = StateObject(wrappedValue: drops)
    }

    /// Where a failure message can be put on the shelf to see how it looks.
    init(library: LibraryStore, importer: BookImporter, onOpen: @escaping (Book) -> Void, previewing: [ImportError]) {
        self.library = library
        self.importer = importer
        self.onOpen = onOpen
        selection = ShelfSelection()
        onExport = { _ in }
        let drops = ShelfDrops(importAll: { await importer.importAll($0) })
        if !previewing.isEmpty { drops.showForPreview(previewing) }
        _drops = StateObject(wrappedValue: drops)
    }

    var body: some View {
        GeometryReader { geometry in
            // A legacy scroller keeps its width even when hidden, which would leave the shelves short of
            // the window's edge. The scroll view is made that much wider and the excess is clipped away.
            ScrollView(.vertical) {
                Shelves(
                    library: library, size: geometry.size, animation: settle, selection: selection, onOpen: onOpen,
                    onRemove: { library.remove(id: $0.id) }, onExport: onExport
                )
                .frame(minHeight: geometry.size.height, alignment: .top)
                // A click on the shelf itself, not on a book, puts the selection down.
                .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection.clear() })
            }
            .scrollIndicators(.hidden)
            .frame(width: geometry.size.width + scrollerWidth, alignment: .leading)
            .frame(width: geometry.size.width, alignment: .leading)
            .clipped()
        }
        .background(LinearGradient(colors: [ShelfStyle.top, ShelfStyle.bottom], startPoint: .top, endPoint: .bottom))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(ShelfStyle.text.opacity(targeted ? 0.45 : 0), lineWidth: 2)
                .padding(8)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.15), value: targeted)
        }
        .overlay(alignment: .bottom) {
            NoticeView(lines: drops.lines, adding: drops.adding)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.25), value: drops.lines)
        .animation(.easeOut(duration: 0.25), value: drops.adding)
        .environment(\.colorScheme, .dark)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await drops.add(files) }
            return true
        } isTargeted: { targeted = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerWidth = Self.reservedScrollerWidth()
        }
    }

    private var settle: Animation? { reduceMotion ? nil : ShelfStyle.settle }

    private static func reservedScrollerWidth() -> CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }
}

/// A shelf's books, identified by the first of them.
private struct ShelfRowBooks: Identifiable {
    let books: [Book]
    var id: String { books[0].id }
    init(_ books: [Book]) { self.books = books }
}

/// The shelves themselves, laid out for a window of `size`.
private struct Shelves: View {
    @ObservedObject var library: LibraryStore
    let size: CGSize
    let animation: Animation?
    let selection: ShelfSelection
    let onOpen: (Book) -> Void
    let onRemove: (Book) -> Void
    let onExport: ([Book]) -> Void

    var body: some View {
        let rows = ShelfLayout.rows(library.others, width: size.width)
        let empties = max(0, ShelfLayout.emptyRowCount(height: size.height) - rows.count)
        LazyVStack(spacing: ShelfLayout.shelfGap) {
            CurrentBookShelf(
                book: library.current, library: library, onOpen: onOpen, onRemove: onRemove, selection: selection,
                onExport: onExport)
            // Keyed by the book each shelf starts with, so a lazy stack notices shelves that appear or
            // change after it first showed.
            ForEach(rows.map(ShelfRowBooks.init)) { row in
                ShelfRow {
                    ForEach(row.books) { book in
                        ShelfBook(
                            book: book, width: 112, library: library, selection: selection, onOpen: onOpen,
                            onRemove: onRemove, onExport: onExport)
                            .transition(.opacity.combined(with: .offset(y: -14)))
                    }
                }
            }
            ForEach(0..<empties, id: \.self) { _ in
                ShelfRow {}
            }
        }
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity)
        .animation(animation, value: library.books.map(\.id))
    }
}

/// A quiet message that sits on the shelf and goes by itself, and a soft line while books are added.
private struct NoticeView: View {
    let lines: [String]
    let adding: Int

    var body: some View {
        if !lines.isEmpty || adding > 0 {
            VStack(spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(ShelfStyle.body(16, italic: true))
                        .foregroundStyle(ShelfStyle.text)
                }
                if adding > 0 {
                    Text(ShelfDrops.progressLine(adding))
                        .font(ShelfStyle.body(15, italic: true))
                        .foregroundStyle(ShelfStyle.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            // Solid, so the rail behind it doesn't show through.
            .background(Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ShelfStyle.text.opacity(0.1)))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }
}
