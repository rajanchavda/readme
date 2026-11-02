import AppKit

/// The table of contents: a quiet sidebar that slides in over the left of the book, with what's
/// beneath it blurred. Chapters already read are dimmed, and the one being read has a small dot. A
/// click, or Return on the selected chapter, chooses it. The window slides it in and out.
final class TOCSidebar: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 280
    /// Clears the title bar, where the traffic lights show.
    private static let topInset: CGFloat = 40
    private static let rowHeight: CGFloat = 28
    private static let indent: CGFloat = 14

    var onChoose: ((TOCEntry) -> Void)?
    private(set) var entries: [TOCEntry] = []
    private var states: [TOCState] = []

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
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
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

    /// Light for Paper and Sepia, dark for Night.
    func setTheme(_ theme: Theme) {
        appearance = NSAppearance(named: theme == .night ? .darkAqua : .aqua)
    }

    /// Fills the list, with `fraction` the start of the spread on screen, and selects the chapter
    /// being read.
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

    @objc private func clicked() {
        choose(table.clickedRow)
    }

    private func chooseSelected() {
        choose(table.selectedRow)
    }

    private func choose(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        onChoose?(entries[row])
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("entry")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ContentsRow ?? ContentsRow()
        cell.identifier = identifier
        cell.show(entries[row], state: states.indices.contains(row) ? states[row] : .unread, step: Self.indent)
        return cell
    }
}

/// One chapter in the contents. Read ones are dimmed, and the one being read is in full ink with a
/// small dot before it.
private final class ContentsRow: NSTableCellView {
    private static let dotSize: CGFloat = 5

    private let title = NSTextField(labelWithString: "")
    private let dot = NSView()
    private var indent: CGFloat = 0

    init() {
        super.init(frame: .zero)
        title.lineBreakMode = .byTruncatingTail
        title.font = .systemFont(ofSize: 13)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(title)
        addSubview(dot)
        textField = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ContentsRow is created in code")
    }

    func show(_ entry: TOCEntry, state: TOCState, step: CGFloat) {
        title.stringValue = entry.title.isEmpty ? "Untitled" : entry.title
        toolTip = entry.title
        indent = 14 + CGFloat(entry.level) * step
        title.textColor = switch state {
        case .read: .tertiaryLabelColor
        case .current: .labelColor
        case .unread: .secondaryLabelColor
        }
        title.font = .systemFont(ofSize: 13, weight: state == .current ? .medium : .regular)
        dot.isHidden = state != .current
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
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
