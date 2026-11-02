import AppKit

/// What a page number typed into the go-to-page field means. Pages are `ReaderLocation.page`: fixed
/// runs of text, numbered from 1.
enum GoToPage {
    /// Where the typed page begins, as a fraction of the book for `BookWebView.go(toFraction:)`. A
    /// number outside the book means the nearest page in it. Nil if it isn't a whole number.
    static func fraction(forTyped typed: String, pageCount: Int) -> Double? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard pageCount > 0, text.wholeMatch(of: /-?[0-9]+/) != nil else { return nil }
        // Too long for an Int is still a number, past one end or the other.
        let number = Int(text) ?? (text.hasPrefix("-") ? 1 : pageCount)
        let page = min(pageCount, max(1, number))
        return Double(page - 1) / Double(pageCount)
    }

    /// What the empty field shows: where the reader is and how many pages there are, such as
    /// "214 of 1,240".
    static func placeholder(page: Int, pageCount: Int, locale: Locale = .current) -> String {
        "\(page.formatted(.number.locale(locale))) of \(pageCount.formatted(.number.locale(locale)))"
    }
}

/// The small quiet field ⌘G shows, for typing a page number into. Return asks to go there, and Esc,
/// or a click anywhere else, closes it without moving.
///
/// Keys typed into it never turn pages, as the reading window leaves keys to a field being typed in.
final class GoToPageField: NSView, NSTextFieldDelegate {
    static let size = NSSize(width: 168, height: 30)

    /// Asked with what was typed. True if it was a page, and the field can close.
    var onGo: ((String) -> Bool)?
    var onClose: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    private let field = NSTextField()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        tint.wantsLayer = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        for view in [backdrop, tint, field] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GoToPageField is created in code")
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        tint.frame = bounds
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: 10, y: ((bounds.height - height) / 2).rounded(), width: bounds.width - 20, height: height)
    }

    /// The toolbar's colours, so the two read as one family.
    func setTheme(_ theme: Theme) {
        tint.layer?.backgroundColor = ReaderToolbar.chrome(theme).cgColor
        field.textColor = ReaderToolbar.ink(theme)
        placeholderColor = ReaderToolbar.ink(theme).withAlphaComponent(0.55)
        if let text = field.placeholderAttributedString?.string { setPlaceholder(text) }
    }

    private var placeholderColor = NSColor.secondaryLabelColor

    private func setPlaceholder(_ text: String) {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .foregroundColor: placeholderColor,
            .paragraphStyle: centred,
            .font: field.font ?? .systemFont(ofSize: 13),
        ])
    }

    /// Empties the field, shows where the reader is, and takes the keyboard.
    func begin(page: Int, pageCount: Int) {
        field.stringValue = ""
        setPlaceholder(GoToPage.placeholder(page: page, pageCount: pageCount))
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if onGo?(field.stringValue) != true { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    /// Leaving the field, by clicking elsewhere, say, closes it.
    func controlTextDidEndEditing(_ notification: Notification) {
        onClose?()
    }
}
