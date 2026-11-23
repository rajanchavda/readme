import SwiftUI

/// Naming a collection: a new one, with the books it was asked for from, or one being renamed.
struct CollectionNameSheet: View {
    let sheet: CollectionSheet
    @ObservedObject var library: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(sheet: CollectionSheet, library: LibraryStore) {
        self.sheet = sheet
        self.library = library
        if case .rename(let id) = sheet {
            _name = State(initialValue: library.collection(id: id)?.name ?? "")
        } else {
            _name = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isCreating ? "New Collection" : "Rename Collection")
                .font(ShelfStyle.title(26))
                .foregroundStyle(ShelfStyle.text)
            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(ShelfStyle.body(14))
                    .foregroundStyle(ShelfStyle.muted)
                TextField("", text: $name)
                    .textFieldStyle(.plain)
                    .font(ShelfStyle.body(17))
                    .foregroundStyle(ShelfStyle.text)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Self.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ShelfStyle.text.opacity(0.12)))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: name) { _, value in
                        if value.count > BookCollection.maxNameLength {
                            name = String(value.prefix(BookCollection.maxNameLength))
                        }
                    }
                    .accessibilityLabel("Name")
                if let conflict {
                    Text(conflict)
                        .font(ShelfStyle.body(14, italic: true))
                        .foregroundStyle(ShelfStyle.muted)
                }
            }
            if isCreating, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggestions")
                        .font(ShelfStyle.body(14))
                        .foregroundStyle(ShelfStyle.muted)
                    Wrap(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                                .buttonStyle(ChipStyle(isActive: false))
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let line = Self.addsLine(count: bookIDs.count) {
                    Text(line)
                        .font(ShelfStyle.body(15, italic: true))
                        .foregroundStyle(ShelfStyle.muted)
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .buttonStyle(ChipStyle(isActive: false))
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create" : "Save", action: commit)
                    .buttonStyle(ChipStyle(isActive: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCommit)
                    .opacity(canCommit ? 1 : 0.4)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 400)
        .background(ShelfStyle.top)
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    private var isCreating: Bool {
        if case .create = sheet { true } else { false }
    }

    private var bookIDs: [String] {
        if case .create(let ids) = sheet { ids } else { [] }
    }

    private var suggestions: [String] { BookCollection.suggestions(excluding: library.collections) }

    private var conflict: String? {
        guard case .rename(let id) = sheet else { return nil }
        return Self.renameConflict(name, renaming: id, in: library.collections)
    }

    private var canCommit: Bool { BookCollection.cleanName(name) != nil && conflict == nil }

    private func commit() {
        guard canCommit else { return }
        switch sheet {
        case .create(let ids):
            // A name that's taken already, whatever its case, puts the books in that one.
            if let collection = library.createCollection(name: name) {
                library.setCollection(collection.id, member: true, ids: ids)
            }
        case .rename(let id):
            library.renameCollection(id: id, to: name)
        }
        dismiss()
    }

    private static let field = Color(red: 0x24 / 255, green: 0x1F / 255, blue: 0x1A / 255)

    /// What Create will add, said under the suggestions. Nothing when it adds no books.
    nonisolated static func addsLine(count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "Adds this book."
        default: "Adds the \(count) selected books."
        }
    }

    /// Why a collection can't be renamed `name`: another one has it, whatever its case and accents.
    nonisolated static func renameConflict(_ name: String, renaming id: UUID, in collections: [BookCollection]) -> String? {
        let key = BookCollection.key(name)
        guard let other = collections.first(where: { $0.id != id && BookCollection.key($0.name) == key }) else { return nil }
        return "There\u{2019}s already a collection called \(other.name)."
    }
}

/// Lays its views out in lines, starting a new line when the next one wouldn't fit.
private struct Wrap: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return place(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, point) in zip(subviews, place(subviews, width: bounds.width).points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + line))
    }
}
