import Foundation

/// Where the reading window goes back to once its layout has changed: the start of the spread it
/// was on before the change began. A page turned since then is where the reader wants to be, so a
/// capture older than the last turn sends them nowhere.
///
/// A live resize or a fullscreen transition is one change from start to end, however many restyles
/// it takes, so its place is kept until it ends and then let go, used or not.
struct PlaceKeeper {
    struct Capture: Equatable {
        var cfi: String
        var turns: Int
    }

    private(set) var turns = 0
    private(set) var layoutChangeCapture: Capture?
    private(set) var isChangingLayout = false

    mutating func turned() {
        turns += 1
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
