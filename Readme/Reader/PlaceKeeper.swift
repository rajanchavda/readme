import Foundation

/// Where the reading window goes back to once its layout has changed: the start of the spread it
/// was on before the change began. A page turned since then is where the reader wants to be, so a
/// capture older than the last turn sends them nowhere.
///
/// A live resize or a fullscreen transition is one change from start to end, however many restyles
/// it takes, so its place is kept until it ends and then let go, used or not.
///
/// The place is where the reader is, which only a turn, a jump or opening the book moves. A layout
/// change shows it on whichever page now holds it, which usually starts a little before it. Going back
/// to that page's start next time would creep back a page at a time, so the place stays as it was.
struct PlaceKeeper {
    struct Capture: Equatable {
        var cfi: String
        var turns: Int
    }

    private(set) var turns = 0
    /// The start of the spread the reader last turned or jumped to, or opened the book at.
    private(set) var place: String?
    private(set) var layoutChangeCapture: Capture?
    private(set) var isChangingLayout = false

    mutating func turned() {
        turns += 1
    }

    mutating func moved(to cfi: String?) {
        place = cfi
    }

    /// Where the reader is, or what's shown if that isn't known yet.
    func place(showing shown: String?) -> String? {
        place ?? shown
    }

    func capture(_ cfi: String?) -> Capture? {
        cfi.map { Capture(cfi: $0, turns: turns) }
    }

    /// The place to go back to, unless a page has turned since the capture.
    func target(_ capture: Capture?) -> String? {
        guard let capture, capture.turns == turns else { return nil }
        return capture.cfi
    }

    mutating func beginLayoutChange(at cfi: String?) {
        guard !isChangingLayout else { return }
        isChangingLayout = true
        layoutChangeCapture = capture(cfi)
    }

    mutating func endLayoutChange() -> Capture? {
        defer {
            isChangingLayout = false
            layoutChangeCapture = nil
        }
        return layoutChangeCapture
    }
}
