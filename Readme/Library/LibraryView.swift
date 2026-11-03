import SwiftUI

/// The bookshelf: the current book on its own shelf, the rest below, and a drop target for new ones.
struct LibraryView: View {
    @ObservedObject var library: LibraryStore
    let importer: BookImporter
    let onOpen: (Book) -> Void

    @State private var notice: Notice?
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Notice: Equatable {
        var id = UUID()
        var lines: [String]
    }

    /// `showing` is a failure message already on the shelf, for checking how it looks.
    init(library: LibraryStore, importer: BookImporter, onOpen: @escaping (Book) -> Void, showing: [ImportError] = []) {
        _notice = State(initialValue: showing.isEmpty ? nil : Notice(lines: Self.messages(for: showing)))
        self.library = library
        self.importer = importer
        self.onOpen = onOpen
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                Shelves(
                    library: library, size: geometry.size, animation: settle, onOpen: onOpen,
                    onRemove: { library.remove(id: $0.id) }
                )
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
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
            if let notice {
                NoticeView(notice: notice)
                    .padding(.bottom, 34)
                    .transition(.opacity)
                    .id(notice.id)
            }
        }
        .environment(\.colorScheme, .dark)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task { await add(files) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private var settle: Animation? { reduceMotion ? nil : ShelfStyle.settle }

    private func add(_ files: [URL]) async {
        let results = await importer.importAll(files)
        let failures = results.compactMap { result -> ImportError? in
            if case .failure(let error) = result { return error }
            return nil
        }
        guard !failures.isEmpty else { return }
        show(Notice(lines: Self.messages(for: failures)))
    }

    private func show(_ new: Notice) {
        withAnimation(.easeOut(duration: 0.2)) { notice = new }
        Task {
            try? await Task.sleep(for: Self.noticeDuration)
            guard notice?.id == new.id else { return }
            withAnimation(.easeOut(duration: 0.6)) { notice = nil }
        }
    }

    static let noticeDuration: Duration = .seconds(4)

    /// One line for each kind of failure, in the order they first happened, however many files failed.
    static func messages(for errors: [ImportError]) -> [String] {
        var seen: [ImportError] = []
        for error in errors where !seen.contains(error) { seen.append(error) }
        return seen.map(message)
    }

    static func message(for error: ImportError) -> String {
        switch error {
        case .copyProtected: "This book is copy-protected, so it can't be opened here."
        case .notAnEPUB: "This file isn't an EPUB book."
        case .unreadable: "This book couldn't be read."
        }
    }
}

/// The shelves themselves, laid out for a window of `size`.
private struct Shelves: View {
    @ObservedObject var library: LibraryStore
    let size: CGSize
    let animation: Animation?
    let onOpen: (Book) -> Void
    let onRemove: (Book) -> Void

    var body: some View {
        let rows = ShelfLayout.rows(library.others, width: size.width)
        let empties = max(0, ShelfLayout.emptyRowCount(height: size.height) - rows.count)
        VStack(spacing: ShelfLayout.shelfGap) {
            CurrentBookShelf(book: library.current, library: library, onOpen: onOpen, onRemove: onRemove)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                ShelfRow {
                    ForEach(row) { book in
                        ShelfBook(book: book, width: 112, library: library, onOpen: onOpen, onRemove: onRemove)
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

/// A quiet message that sits on the shelf and goes by itself.
private struct NoticeView: View {
    let notice: LibraryView.Notice

    var body: some View {
        VStack(spacing: 4) {
            ForEach(notice.lines, id: \.self) { line in
                Text(line)
                    .font(ShelfStyle.body(16, italic: true))
                    .foregroundStyle(ShelfStyle.text)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
