import AppKit

/// The floating box ⌘F shows: a field to type into, how many matches there are, and a list of them
/// with the words around each. Arrows move through the list, Return or a click goes to a match, and
/// Esc closes it without moving.
///
/// The field keeps the keyboard the whole time. The list never takes it, so a click on a row picks
/// the row rather than ending the typing and closing the box first.
final class SearchBox: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 420
    /// How long typing has to stop before a search runs.
    static let pause: Duration = .milliseconds(250)
    static let visibleRows = 7
    private static let fieldHeight: CGFloat = 40
    private static let countHeight: CGFloat = 22
    private static let rowHeight: CGFloat = 30
    /// The most of what comes before a match that a row shows, so the match itself stays in view.
    private static let preLength = 32

    /// Called with what's typed, once typing pauses.
    var onQuery: ((String) -> Void)?
    /// Called with the row the reader chose.
    var onPick: ((Int) -> Void)?
    var onClose: (() -> Void)?
    /// Called when the box wants another height, as the list grows or shrinks.
    var onResize: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let tint = NSView()
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = RowList()
    private var outcome: SearchOutcome?
    private(set) var selected: Int?
    private var pending: Task<Void, Never>?
    private var ink = NSColor.labelColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        tint.wantsLayer = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = "Find in book"
        field.delegate = self
        count.font = .systemFont(ofSize: 11)
        count.lineBreakMode = .byTruncatingTail
        let column = NSTableColumn(identifier: .init("match"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.onPick = { [weak self] row in self?.pick(row) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        for view in [backdrop, tint, field, count, scroll] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SearchBox is created in code")
    }

    /// Tall enough for the field, the count once there's a search, and up to `visibleRows` rows.
    var preferredHeight: CGFloat {
        guard let outcome else { return Self.fieldHeight }
        let rows = min(outcome.matches.count, Self.visibleRows)
        return Self.fieldHeight + Self.countHeight + CGFloat(rows) * Self.rowHeight + (rows > 0 ? 6 : 0)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        tint.frame = bounds
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(
            x: 14, y: ((Self.fieldHeight - height) / 2).rounded(), width: bounds.width - 28, height: height)
        count.frame = NSRect(x: 14, y: Self.fieldHeight, width: bounds.width - 28, height: Self.countHeight - 6)
        let top = Self.fieldHeight + Self.countHeight
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - 6))
        table.tableColumns.first?.width = scroll.contentSize.width
    }

    /// The toolbar's colours, as the go-to-page field has them.
    func setTheme(_ theme: Theme) {
        ink = ReaderToolbar.ink(theme)
        tint.layer?.backgroundColor = ReaderToolbar.chrome(theme).cgColor
        field.textColor = ink
        field.placeholderAttributedString = NSAttributedString(string: "Find in book", attributes: [
            .foregroundColor: ink.withAlphaComponent(0.45), .font: field.font ?? .systemFont(ofSize: 15),
        ])
        count.textColor = ink.withAlphaComponent(0.55)
        table.reloadData()
    }

    /// Fills the box with a search kept from before, if any, and takes the keyboard.
    func begin(query: String, outcome: SearchOutcome?, selected: Int?) {
        pending?.cancel()
        field.stringValue = query
        self.selected = selected
        show(outcome, for: query)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Shows what a search found. Nil shows no list and no count.
    func show(_ outcome: SearchOutcome?, for query: String) {
        self.outcome = outcome
        if let outcome {
            if let row = selected, !outcome.matches.indices.contains(row) { selected = nil }
            if selected == nil, !outcome.matches.isEmpty { selected = 0 }
        } else {
            selected = nil
        }
        count.stringValue = outcome.map(SearchResults.countText) ?? ""
        table.reloadData()
        if let selected { table.scrollRowToVisible(selected) }
        onResize?()
        needsLayout = true
    }

    /// Where a row's middle is, in the box's coordinates. For tests.
    func rowCenter(_ row: Int) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return convert(NSPoint(x: rect.midX, y: rect.midY), from: table)
    }

    private func pick(_ row: Int) {
        guard let outcome, outcome.matches.indices.contains(row) else { return }
        selected = row
        onPick?(row)
    }

    private func move(by step: Int) {
        guard let outcome, !outcome.matches.isEmpty else { return }
        let row = min(outcome.matches.count - 1, max(0, (selected ?? -1) + step))
        selected = row
        table.reloadData()
        table.scrollRowToVisible(row)
    }

    // MARK: Field

    func controlTextDidChange(_ notification: Notification) {
        pending?.cancel()
        let query = field.stringValue
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            self?.onQuery?(query)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selected { pick(selected) } else { NSSound.beep() }
        case #selector(NSResponder.cancelOperation(_:)):
            pending?.cancel()
            onClose?()
        default:
            return false
        }
        return true
    }

    /// Leaving the field, as when the window loses the keyboard, closes the box.
    func controlTextDidEndEditing(_ notification: Notification) {
        pending?.cancel()
        onClose?()
    }

    // MARK: List

    func numberOfRows(in tableView: NSTableView) -> Int {
        outcome?.matches.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let match = outcome?.matches[row] else { return nil }
        let cell = tableView.makeView(withIdentifier: MatchRow.identifier, owner: nil) as? MatchRow ?? MatchRow()
        cell.show(match, excerpt: excerpt(match), ink: ink, isSelected: row == selected)
        return cell
    }

    /// The words around the match on one line, with the match itself in the heavier weight.
    private func excerpt(_ match: SearchMatch) -> NSAttributedString {
        let quiet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink.withAlphaComponent(0.7),
        ]
        var pre = match.pre
        if pre.count > Self.preLength { pre = "…" + pre.suffix(Self.preLength).drop { $0 != " " } }
        let text = NSMutableAttributedString(string: pre, attributes: quiet)
        text.append(NSAttributedString(string: match.match, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink,
        ]))
        text.append(NSAttributedString(string: match.post, attributes: quiet))
        return text
    }
}

/// The list of matches. It never takes the keyboard from the field, and a click picks the row under it.
private final class RowList: NSTableView {
    var onPick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    /// The rows' labels never take the click, so it always comes here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onPick?(row) }
    }
}

/// One match: the excerpt, and its page and chapter at the right.
private final class MatchRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("MatchRow")

    private let excerpt = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        wantsLayer = true
        layer?.cornerRadius = 6
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.truncatesLastVisibleLine = true
        detail.font = .systemFont(ofSize: 11)
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingTail
        for view in [excerpt, detail] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MatchRow is created in code")
    }

    func show(_ match: SearchMatch, excerpt text: NSAttributedString, ink: NSColor, isSelected: Bool) {
        excerpt.attributedStringValue = text
        detail.stringValue = SearchResults.detail(match)
        detail.textColor = ink.withAlphaComponent(0.45)
        layer?.backgroundColor = isSelected ? ink.withAlphaComponent(0.1).cgColor : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 6, dy: 0)
        let detailWidth = min(150, ceil(detail.intrinsicContentSize.width))
        let height = excerpt.intrinsicContentSize.height
        let y = ((bounds.height - height) / 2).rounded()
        detail.frame = NSRect(x: inset.maxX - 8 - detailWidth, y: y, width: detailWidth, height: height)
        excerpt.frame = NSRect(x: inset.minX + 8, y: y, width: max(0, detail.frame.minX - 12 - inset.minX - 8),
                               height: height)
    }
}
