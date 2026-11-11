import AppKit
import SwiftUI

/// The shelf's warm, dark palette from the mockup. It is the same in every reader theme.
enum ShelfStyle {
    static let top = Color(red: 0x3A / 255, green: 0x33 / 255, blue: 0x2C / 255)
    static let bottom = Color(red: 0x2F / 255, green: 0x29 / 255, blue: 0x23 / 255)
    static let text = Color(red: 0xF5 / 255, green: 0xEF / 255, blue: 0xE2 / 255)
    static let soft = Color(red: 0xD9 / 255, green: 0xCD / 255, blue: 0xB7 / 255)
    static let muted = Color(red: 0xB8 / 255, green: 0xA9 / 255, blue: 0x8F / 255)
    static let woodTop = Color(red: 0x6B / 255, green: 0x5A / 255, blue: 0x46 / 255)
    static let woodBottom = Color(red: 0x4A / 255, green: 0x3D / 255, blue: 0x2F / 255)

    /// The easing of a cover lifting under the pointer.
    static let lift = Animation.easeOut(duration: 0.2)
    /// A book settling onto a shelf, or the shelf closing up.
    static let settle = Animation.spring(response: 0.45, dampingFraction: 0.78)

    static func title(_ size: CGFloat) -> Font {
        // Fraunces is variable; the mockup sets the headline at weight 300.
        let base = NSFont(name: "Fraunces", size: size)
        let light = base.flatMap {
            NSFont(descriptor: $0.fontDescriptor.addingAttributes([.variation: [2_003_265_652: 300]]), size: size)
        }
        return light.map(Font.init) ?? .system(size: size, weight: .light, design: .serif)
    }

    static func body(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "EBGaramond-Italic" : "EB Garamond", size: size)
    }
}

/// One shelf: books standing on a wooden rail that runs the width of the window.
struct ShelfRow<Content: View>: View {
    var height: CGFloat = ShelfLayout.shelfHeight
    var gap: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .bottom, spacing: gap) {
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 54)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
        .background(alignment: .bottom) {
            // Below the shelf's own bottom edge, where the books stand.
            Rectangle()
                .fill(LinearGradient(colors: [ShelfStyle.woodTop, ShelfStyle.woodBottom], startPoint: .top, endPoint: .bottom))
                .frame(height: 14)
                .shadow(color: .black.opacity(0.45), radius: 9, x: 0, y: 10)
                .offset(y: 14)
        }
    }
}

/// A cover that lifts a little under the pointer and opens its book when clicked. ⌘- and Shift-clicks
/// pick it out instead, and a picked-out cover has a ring round it.
struct ShelfBook: View {
    let book: Book
    let width: CGFloat
    let library: LibraryStore
    var extraShadow = false
    @ObservedObject var selection: ShelfSelection
    let onOpen: (Book) -> Void
    let onRemove: (Book) -> Void
    let onExport: ([Book]) -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The books as the shelf shows them.
    private var order: [String] {
        ([library.current].compactMap { $0 } + library.others).map(\.id)
    }

    var body: some View {
        Button {
            if selection.click(book.id, modifiers: NSEvent.modifierFlags, order: order) == .open { onOpen(book) }
        } label: {
            BookCoverView(book: book, width: width, library: library)
                .shadow(color: .black.opacity(extraShadow ? 0.3 : 0), radius: 12, x: 0, y: 8)
                .overlay {
                    if selection.ids.contains(book.id) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .offset(y: hovering ? -8 : 0)
        .animation(reduceMotion ? nil : ShelfStyle.lift, value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(selection.menuTitle(rightClicked: book.id)) {
                onExport(selection.targets(rightClicked: book.id, order: order).compactMap(library.book(id:)))
            }
            Button("Remove", role: .destructive) { onRemove(book) }
        }
        .accessibilityLabel([book.title, book.author].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens the book")
        .accessibilityAction(named: "Remove") { onRemove(book) }
    }
}
