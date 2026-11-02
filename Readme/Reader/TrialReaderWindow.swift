import AppKit
import OSLog
import UniformTypeIdentifiers

/// A plain window for trying the curl on real books: fixed size, landscape and two pages, because
/// foliate forces one column in a portrait view. The real reading window replaces it.
@MainActor
final class TrialReaderWindow: NSObject, NSWindowDelegate {
    /// One open book and everything turning its pages. Each book gets a new one.
    private struct Session {
        let book: BookWebView
        let curl: CurlView
        let cache: SpreadCache
        let turns: TurnCoordinator
    }

    /// The mockup's stage and margin, which make the book the size the curl was approved at.
    private static let contentSize = NSSize(width: 1048, height: 620)
    /// Room for the page to overflow the book as it lifts towards the reader.
    private static let deskMargin: CGFloat = 34
    /// The mockup's paper theme, until real themes arrive.
    private static let paper = "html, body { background: #F5EFE2 !important; color: #2B261F !important }"
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "TrialReaderWindow")

    private let window: NSWindow
    private let desk: TrialDeskView
    private let hint: NSTextField
    private var session: Session?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var opening: Task<Void, Never>?

    override init() {
        let frame = NSRect(origin: .zero, size: Self.contentSize)
        window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Readme"
        desk = TrialDeskView(
            frame: frame, bookFrame: frame.insetBy(dx: Self.deskMargin, dy: Self.deskMargin))
        window.contentView = desk
        hint = NSTextField(labelWithString: "Press ⌘O to open a book")
        hint.textColor = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 0.7)
        hint.font = .systemFont(ofSize: 15)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: (frame.width - hint.frame.width) / 2, y: (frame.height - hint.frame.height) / 2)
        desk.addSubview(hint)
        super.init()
        window.center()

        desk.onEdgeClick = { [weak self] direction in self?.session?.turns.turn(direction) }
        // A monitor, because the web view takes keys once it's been clicked.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        desk.onSwipe = { [weak self] signal in self?.session?.turns.follow(signal) }
        window.delegate = self
        // A monitor, because the web view takes scrolling over the book. Nothing in it scrolls, as
        // the book's in pages.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.window.attachedSheet == nil else { return event }
            self.desk.scrollWheel(with: event)
            return nil
        }
    }

    /// The end of a gesture may never reach a window that's lost the keyboard, and no page should stay
    /// held up for that.
    func windowDidResignKey(_ notification: Notification) {
        desk.abandonSwipe()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func chooseBook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.open(url)
        }
    }

    func open(_ url: URL) {
        opening?.cancel()
        session?.curl.end()
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()

        let bookFrame = desk.bounds.insetBy(dx: Self.deskMargin, dy: Self.deskMargin)
        let book = BookWebView(frame: bookFrame)
        let curl = CurlView(frame: bookFrame)
        desk.addSubview(book)
        desk.addSubview(curl)
        let cache = SpreadCache(visible: book)
        session = Session(book: book, curl: curl, cache: cache, turns: TurnCoordinator(book: book, cache: cache, curl: curl))
        hint.isHidden = true

        opening = Task { [weak self] in
            do {
                await book.applyStyles(css: Self.paper, columns: 2)
                let location = try await book.open(url, at: nil)
                guard !Task.isCancelled else { return }
                self?.window.title = url.deletingPathExtension().lastPathComponent
                await cache.refresh(around: location)
            } catch {
                Self.log.error("Opening failed: \(String(describing: error), privacy: .public)")
                guard !Task.isCancelled else { return }
                self?.showFailure(of: url)
            }
        }
    }

    private func showFailure(of url: URL) {
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()
        session = nil
        hint.stringValue = "\(url.lastPathComponent) couldn't be opened"
        hint.sizeToFit()
        hint.frame.origin.x = (desk.bounds.width - hint.frame.width) / 2
        hint.isHidden = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let session
        else { return false }
        switch event.specialKey {
        case .rightArrow:
            session.turns.turn(.forward)
            return true
        case .leftArrow:
            session.turns.turn(.backward)
            return true
        default:
            guard event.charactersIgnoringModifiers == " " else { return false }
            session.turns.turn(.forward)
            return true
        }
    }
}

/// The surface the book lies on. It takes clicks on the outer parts of the book, which turn pages,
/// and leaves the rest of the book to the web view, so text can still be selected. Clicks on the bare
/// desk do nothing. It also reads swipes from scrolling, wherever over the window that happens.
final class TrialDeskView: NSView {
    private static let edgeShare: CGFloat = 0.2

    var onEdgeClick: ((TurnDirection) -> Void)?
    var onSwipe: ((SwipeSignal) -> Void)?
    private let bookFrame: NSRect
    private var gesture = SwipeGesture()

    init(frame: NSRect, bookFrame: NSRect) {
        self.bookFrame = bookFrame
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = CGColor(srgbRed: 0x3A / 255, green: 0x33 / 255, blue: 0x2C / 255, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TrialDeskView is created in code")
    }

    /// Which way a click at `point` turns the page, if it does.
    func turn(at point: NSPoint) -> TurnDirection? {
        guard bookFrame.contains(point) else { return nil }
        let band = bookFrame.width * Self.edgeShare
        if point.x < bookFrame.minX + band { return .backward }
        if point.x > bookFrame.maxX - band { return .forward }
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return turn(at: local) != nil ? self : super.hitTest(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard let direction = turn(at: convert(event.locationInWindow, from: nil)) else { return }
        onEdgeClick?(direction)
    }

    /// Only a trackpad-style gesture has a phase, so a mouse wheel does nothing, and momentum has none
    /// of its own: it comes after the fingers have gone, with the page no longer theirs.
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, let phase = Self.gesturePhase(of: event) else { return }
        send(gesture.handle(
            phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, at: event.timestamp))
    }

    func abandonSwipe() {
        send(gesture.abandon())
    }

    private func send(_ signals: [SwipeSignal]) {
        signals.forEach { onSwipe?($0) }
    }

    private static func gesturePhase(of event: NSEvent) -> SwipeGesture.Phase? {
        switch event.phase {
        case .began: .began
        case .changed, .stationary: .changed
        case .ended: .ended
        case .cancelled: .cancelled
        default: nil
        }
    }
}
