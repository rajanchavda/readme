import AppKit
import SwiftUI

/// Which books on the shelf are picked out, for exporting them. A plain click still opens a book and
/// clears the selection; ⌘-click picks one in or out, and Shift-click picks the run from the last one
/// picked, as in the Finder.
@MainActor
final class ShelfSelection: ObservableObject {
    enum Outcome: Equatable {
        /// Open the book clicked.
        case open
        /// The selection changed instead.
        case changed
    }

    @Published private(set) var ids: Set<String> = []
    private var anchor: String?

    /// `order` is the books as the shelf shows them, the current one first.
    func click(_ id: String, modifiers: NSEvent.ModifierFlags, order: [String]) -> Outcome {
        if modifiers.contains(.command) {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            return .changed
        }
        if modifiers.contains(.shift) {
            guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
                ids = [id]
                self.anchor = id
                return .changed
            }
            ids = Set(order[min(from, to)...max(from, to)])
            return .changed
        }
        clear()
        return .open
    }

    func clear() {
        ids = []
        anchor = nil
    }

    /// The books a right-click on `id` exports: the selection, in shelf order, if `id` is in it, and
    /// otherwise just `id`.
    func targets(rightClicked id: String, order: [String]) -> [String] {
        ids.contains(id) ? order.filter(ids.contains) : [id]
    }

    func menuTitle(rightClicked id: String) -> String {
        ids.contains(id) && ids.count > 1 ? "Export \(ids.count) Books…" : "Export…"
    }

    /// The pin item for `count` books: it unpins when every one of them is pinned, and pins otherwise.
    static func pinMenuTitle(count: Int, allPinned: Bool) -> String {
        switch (allPinned, count > 1) {
        case (true, true): "Unpin \(count) Books"
        case (true, false): "Unpin"
        case (false, true): "Pin \(count) Books to Front"
        case (false, false): "Pin to Front"
        }
    }
}
