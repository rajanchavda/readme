import AppKit
import SwiftUI

/// The row of chips on the search's line: All, Reading and Finished when they have books, the
/// collections by name, then +. Chips that don't fit go into a More menu, and the active one is
/// always on the row.
struct CollectionChips: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject var collections: ShelfCollections
    /// The room between the window's buttons and the search.
    let available: CGFloat

    var body: some View {
        let chips = [Chip.all] + ShelfCollections.builtInChips(library.books).map(Chip.builtIn)
            + library.collections.map(Chip.collection)
        let active = collections.filter(in: library)
        let activeIndex = chips.firstIndex { $0.id == active } ?? 0
        let fit = ChipRowLayout.fit(
            widths: chips.map { Self.width(of: $0.name) }, active: activeIndex, available: available,
            moreWidth: Self.width(of: "99 more") + 16, addWidth: Self.height)
        HStack(spacing: ChipRowLayout.gap) {
            ForEach(fit.visible.map { chips[$0] }) { chip in
                chipButton(chip, isActive: chip.index(in: chips) == activeIndex)
            }
            if !fit.overflow.isEmpty {
                moreMenu(fit.overflow.map { chips[$0] })
            }
            Button {
                collections.sheet = .create(bookIDs: [])
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: Self.height, height: Self.height)
            }
            .buttonStyle(ChipStyle(isActive: false, isRound: true))
            .help("New Collection")
            .accessibilityLabel("New Collection")
        }
        .fixedSize()
    }

    private func chipButton(_ chip: Chip, isActive: Bool) -> some View {
        Button {
            collections.filter = chip.id
        } label: {
            Text(chip.name).lineLimit(1)
        }
        .buttonStyle(ChipStyle(isActive: isActive))
        .accessibilityLabel(chip.collectionID == nil ? chip.name : "\(chip.name), collection")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            if let id = chip.collectionID {
                Button("Rename…") { collections.sheet = .rename(id) }
                Button("Delete Collection") { askToDelete(id) }
            }
        }
    }

    private func moreMenu(_ chips: [Chip]) -> some View {
        Menu {
            ForEach(chips) { chip in
                Button(chip.name) { collections.filter = chip.id }
            }
        } label: {
            HStack(spacing: 6) {
                Text("\(chips.count) more")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(ChipStyle(isActive: false))
        .fixedSize()
        .accessibilityLabel("\(chips.count) more collections")
    }

    /// An empty collection goes at once; one with books in it asks first.
    private func askToDelete(_ id: UUID) {
        if ShelfCollections.shown(library.books, in: id).isEmpty {
            collections.delete(id, from: library)
        } else {
            collections.confirmingDelete = id
        }
    }

    static let height: CGFloat = 30
    private static let font = NSFont(name: "EB Garamond", size: 16) ?? .systemFont(ofSize: 16)

    /// A chip's width with `name` in it: the text, its padding and its outline.
    static func width(of name: String) -> CGFloat {
        let text = NSAttributedString(string: name, attributes: [.font: font]).size().width
        return ceil(text) + 2 * ChipStyle.padding + 2
    }
}

/// One chip: All, Reading, Finished, or a collection.
private struct Chip: Identifiable {
    let id: ShelfFilter
    let name: String

    /// The collection it is, if it's one: only those can be renamed or deleted.
    var collectionID: UUID? {
        if case .collection(let id) = id { id } else { nil }
    }

    static let all = Chip(id: .all, name: "All")
    static func builtIn(_ filter: ShelfFilter) -> Chip { Chip(id: filter, name: filter == .reading ? "Reading" : "Finished") }
    static func collection(_ collection: BookCollection) -> Chip { Chip(id: .collection(collection.id), name: collection.name) }

    func index(in chips: [Chip]) -> Int? { chips.firstIndex { $0.id == id } }
}

/// A capsule as tall as the search field: filled cream when it's the one showing, outlined otherwise.
struct ChipStyle: ButtonStyle {
    static let padding: CGFloat = 14
    var isActive: Bool
    var isRound = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ShelfStyle.body(16))
            .foregroundStyle(isActive ? ShelfStyle.bottom : ShelfStyle.soft)
            .padding(.horizontal, isRound ? 0 : Self.padding)
            .frame(height: CollectionChips.height)
            .background {
                if isActive {
                    Capsule().fill(ShelfStyle.text)
                } else {
                    // Solid, as the search field is, so covers scrolling under the row don't show through.
                    Capsule().fill(ShelfStyle.field)
                    Capsule().fill(ShelfStyle.text.opacity(configuration.isPressed ? 0.12 : 0))
                    Capsule().strokeBorder(ShelfStyle.text.opacity(0.14))
                }
            }
            .contentShape(Capsule())
    }
}
