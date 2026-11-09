import AppKit

/// The small bar that floats by the words the reader selected, with one button: Highlight. Over a
/// highlight already there it says Remove. It lives in the window, never in the page, so the curl's
/// snapshots don't catch it. Its colours are the theme's ink, as in the sidebars.
final class HighlightBar: NSVisualEffectView {
    enum Mode: Equatable {
        case add
        case remove

        var title: String {
            switch self {
            case .add: "Highlight"
            case .remove: "Remove"
            }
        }
    }

    static let size = NSSize(width: 104, height: 30)
    /// The gap between the bar and the words.
    static let gap: CGFloat = 8

    var onPress: ((Mode) -> Void)?
    private(set) var mode = Mode.add
    private let button = NSButton()

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.size.height / 2
        layer?.masksToBounds = true
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(pressed)
        button.frame = bounds
        button.autoresizingMask = [.width, .height]
        addSubview(button)
        show(.add)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HighlightBar is created in code")
    }

    func show(_ mode: Mode) {
        self.mode = mode
        button.title = mode.title
        button.setAccessibilityLabel(mode.title)
    }

    func setTheme(_ theme: Theme) {
        appearance = NSAppearance(named: theme == .night ? .darkAqua : .aqua)
        button.contentTintColor = ReadingCSS.colors(theme).ink
    }

    /// Where the bar goes for words at `target`, in the coordinates of the view it's in, which is
    /// `bounds` and has its origin at the bottom left: centred above them, or below if there's no
    /// room, and kept inside.
    static func frame(for target: CGRect, in bounds: CGRect) -> CGRect {
        let inset: CGFloat = 8
        var x = target.midX - size.width / 2
        x = min(max(x, bounds.minX + inset), bounds.maxX - size.width - inset)
        var y = target.maxY + gap
        // The title bar's strip at the top isn't somewhere to float.
        if y + size.height > bounds.maxY - 36 { y = target.minY - gap - size.height }
        y = min(max(y, bounds.minY + inset), bounds.maxY - size.height - inset)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    @objc private func pressed() {
        onPress?(mode)
    }

    /// For tests.
    func press() { pressed() }
}
