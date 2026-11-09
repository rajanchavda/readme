import AppKit

/// The table of contents: a quiet sidebar that slides in over the left of the book, with what's
/// beneath it blurred. Chapters already read are dimmed, and the one being read is in full ink with a
/// small dot. A click, or Return on the selected chapter, chooses it. The window slides it in and out.
///
/// Every colour is the theme's ink at some strength, never the system's accent. The selection, which
/// the arrows move, is a faint wash of it, and has nothing to do with which chapter is being read.
final class TOCSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 280
    /// Clears the title bar, where the traffic lights show.
    private static let topInset: CGFloat = 40
    private static let rowHeight: CGFloat = 28
    private static let indent: CGFloat = 14

    var onChoose: ((TOCEntry) -> Void)?
    private(set) var entries: [TOCEntry] = []
    private var states: [TOCState] = []
    private var ink = ReadingCSS.colors(.paper).ink

    private let scroll = NSScrollView()
    private let table = ContentsTable()

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .sidebar
        blendingMode = .withinWindow
        state = .active

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] in self?.chooseSelected() }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.topInset, left: 0, bottom: 12, right: 0)
        scroll.documentView = table
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)

        // A hairline along the edge the book's on.
        let edge = NSBox(frame: NSRect(x: frame.width - 1, y: 0, width: 1, height: frame.height))
        edge.boxType = .separator
        edge.autoresizingMask = [.minXMargin, .height]
        addSubview(edge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TOCSidebar is created in code")
    }

    /// Light for Paper and Sepia, dark for Night, with the theme's ink.
    func setTheme(_ theme: Theme) {
        appearance = NSAppearance(named: theme == .night ? .darkAqua : .aqua)
        ink = ReadingCSS.colors(theme).ink
        table.reloadData()
    }

    /// Fills the list, with `fraction` the start of the spread on screen, and selects the chapter
    /// being read, so the arrows start from there.
    func show(_ entries: [TOCEntry], at fraction: Double) {
        self.entries = entries
        states = TOCProgress.states(entries: entries, fraction: fraction)
        table.reloadData()
        let current = states.firstIndex(of: .current) ?? 0
        if !entries.isEmpty {
            table.selectRowIndexes([current], byExtendingSelection: false)
            table.scrollRowToVisible(current)
        }
    }

    /// Hands the keyboard to the list.
    func focus() {
        window?.makeFirstResponder(table)
    }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// Chooses the entry in `row`, unless it has no place in the book.
    func choose(row: Int) {
        guard entries.indices.contains(row), entries[row].fraction != nil else { return }
        onChoose?(entries[row])
    }

    @objc private func clicked() {
        choose(row: table.clickedRow)
    }

    private func chooseSelected() {
        choose(row: table.selectedRow)
    }

    // MARK: Colours

    /// The faint wash the selection is drawn with.
    var selectionColor: NSColor { ink.withAlphaComponent(0.08) }

    private func titleColor(_ entry: TOCEntry, _ state: TOCState) -> NSColor {
        guard entry.fraction != nil else { return ink.withAlphaComponent(0.3) }
        return switch state {
        case .read: ink.withAlphaComponent(0.45)
        case .current: ink
        case .unread: ink.withAlphaComponent(0.75)
        }
    }

    // MARK: What the list shows, for tests

    func select(row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    func isRowSelected(_ row: Int) -> Bool {
        table.selectedRowIndexes.contains(row)
    }

    func isMarkedCurrent(row: Int) -> Bool {
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsRow)?.isMarkedCurrent ?? false
    }

    func titleColor(row: Int) -> NSColor? {
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ContentsRow)?.titleColor
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("selection")
        let rowView = tableView.makeView(withIdentifier: identifier, owner: nil) as? ContentsRowView ?? ContentsRowView()
        rowView.identifier = identifier
        rowView.wash = selectionColor
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ContentsRow ?? ContentsRow()
        cell.identifier = identifier
        let entry = entries[row]
        let state = states.indices.contains(row) ? states[row] : .unread
        cell.show(entry, isCurrent: state == .current, color: titleColor(entry, state), ink: ink, step: Self.indent)
        return cell
    }
}

/// Draws the selection as a faint rounded wash of the ink, whether or not the list has the keyboard,
/// in place of the system's accent.
private final class ContentsRowView: NSTableRowView {
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

/// One chapter in the contents. Its colour is set outright, so a selection never changes it. The one
/// being read has a small dot before it.
private final class ContentsRow: NSTableCellView {
    private static let dotSize: CGFloat = 5

    private let title = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var indent: CGFloat = 0
    private(set) var isMarkedCurrent = false
    var titleColor: NSColor? { title.textColor }

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(title)
        addSubview(dot)
        // Not the cell's `textField`, which a table recolours for its selection.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ContentsRow is created in code")
    }

    func show(_ entry: TOCEntry, isCurrent: Bool, color: NSColor, ink: NSColor, step: CGFloat) {
        title.stringValue = entry.title.isEmpty ? "Untitled" : entry.title
        toolTip = entry.title
        indent = 14 + CGFloat(entry.level) * step
        title.textColor = color
        title.font = .systemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)
        isMarkedCurrent = isCurrent
        dot.isHidden = !isCurrent
        dot.layer?.backgroundColor = ink.cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = title.intrinsicContentSize.height
        title.frame = NSRect(
            x: indent, y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - indent - 10), height: height)
        dot.frame = NSRect(
            x: indent - 9, y: ((bounds.height - Self.dotSize) / 2).rounded(), width: Self.dotSize, height: Self.dotSize)
    }
}

/// Return chooses the selected chapter. Arrows move through the list as in any table.
private final class ContentsTable: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return and the keypad's Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}
