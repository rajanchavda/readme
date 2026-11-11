import AppKit

/// The panel ? shows over the book: every shortcut in two columns of groups, each row a few words
/// on the left and its keys, drawn as key caps, on the right. It's coloured like the toolbar, as the
/// search box is.
final class ShortcutsPanel: NSView {
    static let width: CGFloat = 600
    private static let inset: CGFloat = 22
    private static let gutter: CGFloat = 28
    private static let titleHeight: CGFloat = 50
    private static let headerHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 26
    private static let sectionGap: CGFloat = 10
    private static let capHeight: CGFloat = 20
    private static let capGap: CGFloat = 4

    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    private let title = NSTextField(labelWithString: "Keyboard Shortcuts")
    private let closeHint = NSTextField(labelWithString: "Esc to close")
    private var headers: [NSTextField] = []
    private var descriptions: [NSTextField] = []
    private var caps: [[KeyCap]] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        tint.wantsLayer = true
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        closeHint.font = .systemFont(ofSize: 11)
        closeHint.alignment = .right
        for view in [backdrop, tint, title, closeHint] { addSubview(view) }
        for section in ShortcutsHelp.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 10.5, weight: .semibold)
            headers.append(header)
            addSubview(header)
            for row in section.rows {
                let label = NSTextField(labelWithString: row.description)
                label.font = .systemFont(ofSize: 13)
                label.lineBreakMode = .byTruncatingTail
                descriptions.append(label)
                addSubview(label)
                let rowCaps = row.keys.map { KeyCap(key: $0) }
                rowCaps.forEach(addSubview)
                caps.append(rowCaps)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutsPanel is created in code")
    }

    /// Tall enough for the title and the longer column.
    static var preferredHeight: CGFloat {
        var tallest: CGFloat = 0
        for sections in ShortcutsHelp.columns {
            var height = CGFloat(max(0, sections.count - 1)) * sectionGap
            for section in sections {
                height += headerHeight + CGFloat(section.rows.count) * rowHeight
            }
            tallest = max(tallest, height)
        }
        return titleHeight + tallest + inset
    }

    override var isFlipped: Bool { true }

    /// Takes clicks, so one on the panel doesn't reach the book or the scrim behind it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        tint.frame = bounds
        let inset = Self.inset
        title.sizeToFit()
        title.frame.origin = NSPoint(x: inset, y: ((Self.titleHeight - title.frame.height) / 2).rounded() + 2)
        closeHint.sizeToFit()
        closeHint.frame.origin = NSPoint(
            x: bounds.width - inset - closeHint.frame.width,
            y: title.frame.midY - closeHint.frame.height / 2)
        let columnWidth = ((bounds.width - 2 * inset - Self.gutter) / 2).rounded(.down)
        var headerIndex = 0
        var rowIndex = 0
        for (column, sections) in ShortcutsHelp.columns.enumerated() {
            let x = inset + CGFloat(column) * (columnWidth + Self.gutter)
            var y = Self.titleHeight
            for (sectionIndex, section) in sections.enumerated() {
                if sectionIndex > 0 { y += Self.sectionGap }
                let header = headers[headerIndex]
                headerIndex += 1
                header.sizeToFit()
                header.frame.origin = NSPoint(x: x, y: y + Self.headerHeight - header.frame.height - 6)
                y += Self.headerHeight
                for _ in section.rows {
                    var right = x + columnWidth
                    for cap in caps[rowIndex].reversed() {
                        let size = cap.fittingSize
                        right -= size.width
                        cap.frame = NSRect(
                            x: right, y: y + ((Self.rowHeight - Self.capHeight) / 2).rounded(),
                            width: size.width, height: Self.capHeight)
                        right -= Self.capGap
                    }
                    let label = descriptions[rowIndex]
                    let height = label.intrinsicContentSize.height
                    label.frame = NSRect(
                        x: x, y: y + ((Self.rowHeight - height) / 2).rounded(),
                        width: max(0, right - 8 - x), height: height)
                    rowIndex += 1
                    y += Self.rowHeight
                }
            }
        }
    }

    /// The toolbar's colours.
    func setTheme(_ theme: Theme) {
        let ink = ReaderToolbar.ink(theme)
        tint.layer?.backgroundColor = ReaderToolbar.chrome(theme).cgColor
        title.textColor = ink
        closeHint.textColor = ink.withAlphaComponent(0.45)
        for header in headers { header.textColor = ink.withAlphaComponent(0.5) }
        for label in descriptions { label.textColor = ink.withAlphaComponent(0.85) }
        for cap in caps.joined() { cap.setInk(ink) }
    }

    /// The keys shown on each row, in order. For tests.
    var shownKeys: [[String]] { caps.map { $0.map(\.key) } }
}

/// One key, or one key with its modifiers, drawn like a key on the keyboard.
private final class KeyCap: NSView {
    let key: String
    private let label: NSTextField

    init(key: String) {
        self.key = key
        label = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("KeyCap is created in code")
    }

    override var fittingSize: NSSize {
        NSSize(width: max(24, ceil(label.intrinsicContentSize.width) + 14), height: 20)
    }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }

    func setInk(_ ink: NSColor) {
        label.textColor = ink
        layer?.backgroundColor = ink.withAlphaComponent(0.1).cgColor
        layer?.borderColor = ink.withAlphaComponent(0.22).cgColor
    }
}
