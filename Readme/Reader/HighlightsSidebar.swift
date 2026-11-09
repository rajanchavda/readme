import AppKit

/// The reader's highlights for the open book, in reading order: a quiet sidebar like the contents,
/// sliding in over the left of the book. Each row is the marked words over the chapter they're in. A
/// click, or Return, goes there; Delete, or the row's menu, removes it.
final class HighlightsSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    static let emptyText = "No highlights yet. Select text to highlight it."
    private static let topInset: CGFloat = 40

    var onChoose: ((Highlight) -> Void)?
    var onRemove: ((Highlight) -> Void)?
    private(set) var highlights: [Highlight] = []
    private var ink = ReadingCSS.colors(.paper).ink

    private let scroll = NSScrollView()
    private let table = HighlightsTable()
    private let empty = NSTextField(wrappingLabelWithString: HighlightsSidebar.emptyText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("highlight"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.chooseRow(self?.table.selectedRow ?? -1) }
        table.onDelete = { [weak self] in self?.removeRow(self?.table.selectedRow ?? -1) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Remove Highlight", action: #selector(removeClicked), keyEquivalent: "").target = self
        table.menu = menu

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.topInset, left: 0, bottom: 12, right: 0)
        scroll.documentView = table
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        empty.alignment = .center
        empty.font = .systemFont(ofSize: 13)
        empty.frame = NSRect(x: 24, y: bounds.height / 2 - 30, width: bounds.width - 48, height: 60)
        empty.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        addSubview(empty)

        let edge = NSBox(frame: NSRect(x: frame.width - 1, y: 0, width: 1, height: frame.height))
        edge.boxType = .separator
        edge.autoresizingMask = [.minXMargin, .height]
        addSubview(edge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HighlightsSidebar is created in code")
    }

    func setTheme(_ theme: Theme) {
        appearance = NSAppearance(named: theme == .night ? .darkAqua : .aqua)
        ink = ReadingCSS.colors(theme).ink
        empty.textColor = ink.withAlphaComponent(0.5)
        table.reloadData()
    }

    func show(_ highlights: [Highlight]) {
        self.highlights = highlights
        empty.isHidden = !highlights.isEmpty
        table.reloadData()
        if !highlights.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func focus() {
        window?.makeFirstResponder(table)
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// For tests.
    func choose(row: Int) { chooseRow(row) }
    func remove(row: Int) { removeRow(row) }

    private func chooseRow(_ row: Int) {
        guard highlights.indices.contains(row) else { return }
        onChoose?(highlights[row])
    }

    private func removeRow(_ row: Int) {
        guard highlights.indices.contains(row) else { return }
        onRemove?(highlights[row])
    }

    @objc private func clicked() { chooseRow(table.clickedRow) }
    @objc private func removeClicked() { removeRow(table.clickedRow) }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { highlights.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = HighlightRowView()
        rowView.wash = ink.withAlphaComponent(0.08)
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HighlightRow ?? HighlightRow()
        cell.identifier = identifier
        cell.show(highlights[row], ink: ink)
        return cell
    }
}

private final class HighlightRowView: NSTableRowView {
    var wash = NSColor.clear {
        didSet { needsDisplay = true }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        wash.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

/// The marked words, two lines at most, over their chapter.
private final class HighlightRow: NSTableCellView {
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private let chapter = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.font = .systemFont(ofSize: 13)
        chapter.lineBreakMode = .byTruncatingTail
        chapter.font = .systemFont(ofSize: 11)
        addSubview(excerpt)
        addSubview(chapter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HighlightRow is created in code")
    }

    func show(_ highlight: Highlight, ink: NSColor) {
        excerpt.stringValue = highlight.text.replacingOccurrences(of: "\n", with: " ")
        chapter.stringValue = highlight.chapterTitle ?? ""
        excerpt.textColor = ink.withAlphaComponent(0.85)
        chapter.textColor = ink.withAlphaComponent(0.45)
        toolTip = highlight.text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - 28)
        chapter.frame = NSRect(x: 14, y: 8, width: width, height: 14)
        excerpt.frame = NSRect(x: 14, y: 26, width: width, height: bounds.height - 32)
    }
}

/// Return goes to the selected highlight, and Delete removes it. Arrows move as in any table.
private final class HighlightsTable: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 51, 117: onDelete?()
        default: super.keyDown(with: event)
        }
    }
}
