import AppKit
import OSLog
import UniformTypeIdentifiers
import WebKit

/// The reading window, as in `docs/mockups/open-book-v2.html`: the book on a desk that takes the
/// theme's colour, a soft shadow down the spine, a hairline of progress along the bottom, and a quiet
/// toolbar that shows only while the mouse moves. It shows one page when it's too narrow for two.
///
/// Every change to the look, whether theme, font, size, line width, window size or fullscreen, lays the
/// book out again, goes back to the spread it was on and refreshes the curl's images, so the next curl
/// never shows the old look.
///
/// It's the app's one window, and the library lies over the book when it's shown, the two crossfading.
/// A book from the library opens behind the picture of the spread it was last left on, if one was kept
/// in this look, so it appears at once and the live page fades in over it once it has landed.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    /// One open book and everything turning its pages. Each book gets a new one.
    private struct Session {
        let book: BookWebView
        let curl: CurlView
        let cache: SpreadCache
        let turns: TurnCoordinator
        /// Which book it is, for its place. Known once the book has been read.
        var bookID: String?
        /// The library's book, if it's one from the library.
        var record: Book?
    }

    var onShowLibrary: (() -> Void)?
    /// Hears where the reader is in a library book: when it has opened, and at each place kept.
    var onRead: ((_ bookID: String, ReaderLocation) -> Void)?
    /// Hears that a library book couldn't be opened, as when its file is no longer a book.
    var onOpenFailed: ((Book) -> Void)?
    /// Hears whether the open book has a reading marker, for the menu.
    var onMarkerChange: ((Bool) -> Void)?
    /// Hears the library being shown, or put away.
    var onShowingLibraryChange: ((Bool) -> Void)?

    /// The mockup's stage, which makes the book the size the curl was approved at.
    private static let contentSize = NSSize(width: 1048, height: 620)
    /// Narrow enough for one page, wide enough for the toolbar.
    private static let minimumSize = NSSize(width: 640, height: 420)
    private static let motion = 0.2
    /// How long the window has to keep its size before the curl's images are made again.
    private static let resizeQuiet: Duration = .milliseconds(150)
    private static let paintTimeout: Duration = .milliseconds(500)
    /// The picture of the spread a book was left on is taken at most this often.
    private static let spreadInterval: Duration = .seconds(1)
    private static let noticeDuration: Duration = .seconds(4)
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "ReaderWindowController")

    private let root = NSView()
    private let desk: DeskView
    /// The library, over the desk, while it's shown.
    private var libraryHost: NSView?
    private(set) var isShowingLibrary = false
    /// The last spread a book was left on, shown under its page until the page is ready.
    private let placeholder = PassThroughView()
    private var placeholderBookID: String?
    private let notice: NSTextField
    private var noticeFading: Task<Void, Never>?
    private let library: LibraryStore?
    private var spreads: LastSpreadCache? { library?.spreads }
    private var spreadMemory: Task<Void, Never>?
    private var spreadWanted = false
    private var lastSpreadAttempt: ContinuousClock.Instant?
    private let cover = PassThroughView()
    private let spine = SpineView()
    private let progressBar = PassThroughView()
    private let hint: NSTextField
    private let toolbarModel: ReaderToolbarModel
    private let toolbar: ReaderToolbarHost
    private let contents = TOCSidebar(frame: NSRect(x: 0, y: 0, width: TOCSidebar.width, height: 600))
    private let contentsScrim = ContentsScrim()
    private let highlightsPanel = HighlightsSidebar(frame: NSRect(x: 0, y: 0, width: TOCSidebar.width, height: 600))
    private let highlightBar = HighlightBar()
    private var isHighlightsShown = false
    /// What the reader selected, which the bar offers to highlight, or the CFI of the highlight it
    /// offers to remove.
    private var selection: BookWebView.SelectionInfo?
    private var targetedHighlight: String?
    private var barShownAt: ContinuousClock.Instant?
    /// The open book's highlights, in reading order.
    private var bookHighlights: [Highlight] = []
    /// The open book's reading marker, if the reader set one.
    private var bookMarker: Marker?
    private let ribbon = MarkerRibbon(frame: NSRect(origin: .zero, size: MarkerRibbon.size))
    private var isRibbonOn = false
    /// True from a turn's start until it has landed, while the ribbon stays off the page.
    private var isTurning = false
    private var turnWatch: Task<Void, Never>?
    private var marking: Task<Void, Never>?
    private let pageField = GoToPageField(frame: NSRect(origin: .zero, size: GoToPageField.size))
    private let searchBox = SearchBox(frame: NSRect(x: 0, y: 0, width: SearchBox.width, height: 40))
    /// Dims the book behind the search box, and closes the box when clicked.
    private let searchScrim = ContentsScrim()
    private(set) var isSearchShown = false
    /// The last search, kept while the book is open so ⌘F comes back to it.
    private(set) var searchQuery = ""
    private(set) var searchOutcome: SearchOutcome?
    private(set) var searchSelection: Int?

    private let defaults: UserDefaults
    /// Where each book was left. Without one, books open at their start and nothing is kept.
    private let positions: PositionStore?
    private var settings: ReaderSettings
    private var session: Session?
    private var layout: BookFrame
    private var isFullscreen = false
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var opening: Task<Void, Never>?
    /// The book being opened, until it's settled at its place.
    private var openingBook: BookWebView?
    private let writer: PlaceWriter?

    /// Restyles run one at a time, and those asked for while one runs are folded into the next.
    private var restyling: Task<Void, Never>?
    private var restyleWanted = false
    private var restyleAnimated = false
    /// Where the queued restyle goes back to, captured before the change it's for began.
    private var restyleCapture: PlaceKeeper.Capture?
    private var places = PlaceKeeper()
    private var resizeSettling: Task<Void, Never>?
    /// True while a resize that isn't a live resize or a fullscreen transition, such as zooming, is
    /// its own layout change, which ends once the window keeps its size.
    private var isResizeOwnChange = false
    private var isResizeSettling = false
    /// Pages don't turn while the old look covers the book.
    private var isCovered = false

    /// The open book's contents, read the first time they're asked for. Empty if it has none.
    private var tableOfContents: [TOCEntry]?
    private var contentsLoading: Task<Void, Never>?
    private var isContentsShown = false
    private var isPageFieldShown = false
    private var jumping: Task<Void, Never>?

    private var idle = IdleTimer()
    private var idleCheck: Task<Void, Never>?
    private var isOverToolbar = false
    private var areTrafficLightsShown = true

    /// Library books are opened from `library`, and it keeps their last spreads.
    init(defaults: UserDefaults = .standard, positions: PositionStore? = nil, library: LibraryStore? = nil) {
        self.defaults = defaults
        self.positions = positions
        self.library = library
        writer = positions.map(PlaceWriter.init(store:))
        settings = ReaderSettings.load(defaults)
        let frame = NSRect(origin: .zero, size: Self.contentSize)
        layout = BookFrame(in: frame.size, settings: settings, fullscreen: false)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Readme"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentMinSize = Self.minimumSize

        desk = DeskView(frame: frame, bookFrame: layout.frame)
        desk.autoresizesSubviews = false
        desk.autoresizingMask = [.width, .height]
        root.frame = frame
        root.wantsLayer = true
        root.addSubview(desk)
        window.contentView = root

        hint = NSTextField(labelWithString: "Press ⌘O to open a book")
        hint.textColor = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 0.7)
        hint.font = .systemFont(ofSize: 15)
        // Only for a file that couldn't be opened: the library is where books are found.
        hint.isHidden = true
        notice = NSTextField(labelWithString: "")
        notice.textColor = hint.textColor
        notice.font = .systemFont(ofSize: 14)
        notice.alignment = .center

        toolbarModel = ReaderToolbarModel(settings: settings)
        toolbar = ReaderToolbarHost(model: toolbarModel)
        super.init(window: window)

        for view in [cover, spine, progressBar, placeholder] { view.wantsLayer = true }
        cover.isHidden = true
        placeholder.isHidden = true
        placeholder.layer?.contentsGravity = .resize
        desk.addSubview(spine)
        desk.addSubview(hint)
        desk.addSubview(progressBar)
        notice.alphaValue = 0
        desk.addSubview(notice)
        ribbon.alphaValue = 0
        desk.addSubview(ribbon, positioned: .above, relativeTo: spine)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        desk.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: desk.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: desk.topAnchor, constant: 12),
        ])
        searchScrim.wantsLayer = true
        searchScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        for view in [pageField, contentsScrim, contents, highlightsPanel, highlightBar, searchScrim, searchBox] as [NSView] {
            view.isHidden = true
            desk.addSubview(view)
        }

        window.delegate = self
        window.setFrameAutosaveName("ReaderWindow")
        if !window.setFrameUsingName("ReaderWindow") { window.center() }
        showTrafficLights(false, animated: false)
        wire()
        installMonitors()
        placeViews()
        applyColors(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReaderWindowController is created in code")
    }

    private func wire() {
        desk.onEdgeClick = { [weak self] direction in self?.turn(direction) }
        desk.onSwipe = { [weak self] signal in
            guard let self, !self.isCovered, let session = self.session else { return }
            // A swipe may turn the page, which is then where the reader wants to stay.
            switch signal {
            case .start:
                self.places.turned()
                self.turnBegan()
            case .release, .abandon:
                session.turns.follow(signal)
                self.watchTurnLanding()
                return
            case .move:
                break
            }
            session.turns.follow(signal)
        }
        // The open contents and the scrim beside them take every click, so one beside them closes them.
        desk.chrome = [contents, highlightsPanel, contentsScrim, pageField, toolbar, highlightBar, searchScrim, searchBox]
        contents.onChoose = { [weak self] entry in self?.choose(entry) }
        contentsScrim.onClick = { [weak self] in
            self?.closeContents()
            self?.closeHighlights()
        }
        highlightsPanel.onChoose = { [weak self] highlight in self?.choose(highlight) }
        highlightsPanel.onRemove = { [weak self] highlight in self?.remove(highlight) }
        highlightBar.onPress = { [weak self] mode in self?.pressedBar(mode) }
        pageField.onGo = { [weak self] typed in self?.goToPage(typed: typed) ?? false }
        pageField.onClose = { [weak self] in self?.closePageField() }
        searchScrim.onClick = { [weak self] in self?.closeSearch() }
        searchBox.onQuery = { [weak self] query in
            guard let self else { return }
            Task { await self.search(query) }
        }
        searchBox.onPick = { [weak self] row in self?.pickSearchMatch(at: row) }
        searchBox.onClose = { [weak self] in self?.closeSearch() }
        searchBox.onResize = { [weak self] in self?.placeSearchBox() }
        // The desk hears the mouse in an inactive window too, for the traffic lights. The toolbar
        // only wakes in the window being read.
        desk.onMouseMoved = { [weak self] point in
            guard let self, !self.isShowingLibrary else { return }
            if self.window?.isKeyWindow == true { self.wake() }
            self.followPointer(to: point)
        }
        desk.onMouseExited = { [weak self] in
            guard let self, !self.isShowingLibrary else { return }
            self.sleep()
            if !self.isFullscreen { self.showTrafficLights(false, animated: true) }
        }
        desk.onAppearanceChange = { [weak self] in self?.restyle(animated: true) }

        toolbarModel.onSettingsChange = { [weak self] settings in self?.change(settings) }
        toolbarModel.onCommand = { [weak self] command in self?.perform(command) }
        toolbarModel.onHover = { [weak self] hovering in
            self?.isOverToolbar = hovering
            if !hovering { self?.wake() }
        }
    }

    /// Removed when the window closes, and put back when it shows again.
    private func installMonitors() {
        guard keyMonitor == nil else { return }
        // A monitor, because the web view takes keys once it's been clicked.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        // A monitor, because the web view takes scrolling over the book. Nothing in it scrolls, as
        // the book's in pages.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, !self.isShowingLibrary else { return event }
            let route = ScrollRoute(
                isOurWindow: event.window === window, hasSheet: window.attachedSheet != nil,
                contents: self.contentsPlace(of: event))
            switch route {
            case .passOn:
                return event
            case .swallow:
                return nil
            case .desk:
                self.desk.scrollWheel(with: event)
                return nil
            }
        }
    }

    // MARK: Showing and opening

    func show() {
        installMonitors()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Asks for one or more EPUBs in a sheet, and hands them to `chosen`.
    func chooseBook(_ chosen: @escaping ([URL]) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            chosen(panel.urls)
        }
    }

    /// The library book that's open, whether or not the library is over it.
    var openBook: Book? {
        guard let session, session.book.isBookOpen else { return nil }
        return session.record
    }

    /// Opens a library book at `cfi`, or where the reader left it, or at its start, and puts the
    /// library away once it has landed. A place that's no longer in the book opens it at the same
    /// share of the way through. A book that won't open is handed to `onOpenFailed`, with the
    /// library left as it was. The book open before it has its place kept first.
    func open(_ book: Book, at cfi: String? = nil) async {
        guard let library else { return }
        if session != nil { await keepPlace() }
        // Taken off the shelf while the book before it was being put away.
        guard library.book(id: book.id) != nil else { return }
        if placeholderBookID != book.id {
            hidePlaceholder()
            showLastSpread(of: book)
        }
        await open(file: library.fileURL(for: book), record: book, at: cfi)
    }

    /// The library book open or opening, whether or not it has landed.
    var currentRecordID: String? { session?.record?.id }

    /// Closes the book, as when it's taken off the shelf. Nothing more is kept for it.
    func closeBook() {
        opening?.cancel()
        openingBook = nil
        spreadMemory?.cancel()
        spreadWanted = false
        closeFailed()
    }

    /// Opens a file that isn't in the library, as the tests do.
    func open(_ url: URL, at cfi: String? = nil) async {
        await open(file: url, record: nil, at: cfi)
    }

    private func open(file url: URL, record: Book?, at cfi: String?) async {
        loadsStarted += 1
        opening?.cancel()
        session?.curl.end()
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()
        cover.removeFromSuperview()
        closeContents()
        closeHighlights()
        hideHighlightBar()
        bookHighlights = []
        setBookMarker(nil)
        turnWatch?.cancel()
        isTurning = false
        closePageField()
        closeSearch()
        searchQuery = ""
        searchOutcome = nil
        searchSelection = nil
        contentsLoading?.cancel()
        tableOfContents = nil

        layout = BookFrame(in: desk.bounds.size, settings: settings, fullscreen: isFullscreen)
        let book = BookWebView(frame: layout.frame)
        let curl = CurlView(frame: layout.frame)
        // Shown once it has the book, so an empty white page never flashes up.
        book.alphaValue = 0
        noticeFading?.cancel()
        notice.alphaValue = 0
        // The spine's shadow belongs to the pages, so it lies on the book and the cover, and the
        // turning page passes over it. The curl draws its own on the pages beneath.
        desk.addSubview(book, positioned: .below, relativeTo: spine)
        desk.addSubview(cover, positioned: .above, relativeTo: book)
        desk.addSubview(curl, positioned: .above, relativeTo: spine)
        // On the pages, under the turning one.
        desk.addSubview(ribbon, positioned: .below, relativeTo: curl)
        let cache = SpreadCache(visible: book)
        let turns = TurnCoordinator(book: book, cache: cache, curl: curl)
        session = Session(book: book, curl: curl, cache: cache, turns: turns, record: record)
        openingBook = book
        places.moved(to: nil)
        book.onRelocate = { [weak self, weak book] location in
            guard let self, let book, self.session?.book === book else { return }
            self.relocated(to: location, in: book)
        }
        book.onSelection = { [weak self, weak book] info in
            guard let self, let book, self.session?.book === book else { return }
            self.selectionChanged(info)
        }
        book.onHighlightClicked = { [weak self, weak book] cfi, rect in
            guard let self, let book, self.session?.book === book else { return }
            self.highlightClicked(cfi, rect: rect)
        }
        // A link is a jump the window didn't make, so it counts as one: when it's followed and when
        // it lands.
        book.onLink = { [weak self, weak book] _ in
            guard let self, let book, self.session?.book === book else { return }
            self.places.turned()
        }
        hint.isHidden = true
        placeViews()
        applyColors(animated: false)

        let opening = Task { [weak self] in
            defer { if self?.openingBook === book { self?.openingBook = nil } }
            do {
                guard let self else { return }
                await book.applyStyles(css: self.css(), columns: self.layout.columns, columnWidth: self.layout.columnWidth)
                var bookID = record?.id
                if bookID == nil { bookID = await self.bookID(of: url) }
                var saved: ReaderLocation?
                if let bookID { saved = await self.positions?.location(bookID: bookID) }
                let start = cfi ?? saved?.cfi
                // How far through the book the place was, for when the place itself is gone.
                let share = saved.flatMap { $0.cfi == start ? $0.fraction : nil }
                guard !Task.isCancelled, self.session?.book === book else { return }
                // Drawn as the book opens, so a marked page never shows bare.
                if let bookID, let store = self.library?.highlights {
                    let marks = await store.highlights(bookID: bookID)
                    guard !Task.isCancelled, self.session?.book === book else { return }
                    self.bookHighlights = marks
                    await book.setHighlights(marks.map(\.cfi), color: Self.highlightColor(self.theme))
                }
                if let bookID, let store = self.library?.markers {
                    let marker = await store.marker(bookID: bookID)
                    guard !Task.isCancelled, self.session?.book === book else { return }
                    self.setBookMarker(marker)
                    await book.setMarker(marker?.cfi)
                }
                let location = try await book.open(url, at: start)
                guard !Task.isCancelled, self.session?.book === book else { return }
                self.session?.bookID = bookID
                // The book opens on the page that holds its place, which starts before it. A place it
                // couldn't find is replaced by where it opened, or by the same share of the way through.
                var place = await book.place() ?? location.cfi
                guard !Task.isCancelled, self.session?.book === book else { return }
                let isLost = start != nil && place != start
                if isLost, let share, share > 0, let found = await book.go(toFraction: share) {
                    guard !Task.isCancelled, self.session?.book === book else { return }
                    place = await book.place() ?? found.cfi
                    guard !Task.isCancelled, self.session?.book === book else { return }
                }
                self.places.moved(to: place)
                let opened = self.places.capture(place)
                self.window?.title = record?.title ?? url.deletingPathExtension().lastPathComponent
                self.show(location)
                await book.settle()
                guard !Task.isCancelled, self.session?.book === book else { return }
                self.openingBook = nil
                // A page turned as the book settled is where the reader now is.
                if isLost || self.places.hasTurned(since: opened), let here = book.currentLocation {
                    self.keep(here, in: book)
                } else if let bookID, let here = book.currentLocation {
                    self.onRead?(bookID, here)
                }
                // The library stays until there's a book to show instead, so one that won't open
                // leaves it where it is.
                if record != nil { self.showBook(animated: true) }
                self.updateRibbon(animated: false)
                // The book opens where it was left. If the reader marked a page elsewhere, it says so.
                if let marker = self.bookMarker, book.currentLocation?.isMarked == false {
                    self.showNotice("Marker on page \(marker.page) — ⌘⇧D to go there")
                }
                // Over the last spread, if that's showing, so the page never dims on its way in.
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.motion
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    book.animator().alphaValue = 1
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.session?.book === book else { return }
                        self.hidePlaceholder()
                    }
                })
                if let here = book.currentLocation { await cache.refresh(around: here) }
                self.rememberSpread()
            } catch {
                Self.log.error("Opening failed: \(String(describing: error), privacy: .public)")
                guard !Task.isCancelled, let self, self.session?.book === book else { return }
                if let record {
                    self.closeFailed()
                    self.onOpenFailed?(record)
                } else {
                    self.showFailure(of: url)
                }
            }
        }
        self.opening = opening
        await opening.value
    }

    private func showFailure(of url: URL) {
        closeFailed()
        hint.stringValue = "\(url.lastPathComponent) couldn't be opened"
        hint.isHidden = false
        placeViews()
    }

    private func closeFailed() {
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()
        session = nil
        hidePlaceholder()
        setBookMarker(nil)
        updateRibbon(animated: false)
        toolbarModel.timeLeft = nil
        window?.title = "Readme"
        placeViews()
    }

    // MARK: The library and the last spread

    /// Lays `view` over the desk, to be shown by `showLibrary`.
    func setLibrary(_ view: NSView) {
        libraryHost?.removeFromSuperview()
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.isHidden = !isShowingLibrary
        view.alphaValue = isShowingLibrary ? 1 : 0
        root.addSubview(view, positioned: .above, relativeTo: desk)
        libraryHost = view
    }

    /// Fades the library in over the book, which stays open beneath it at its place.
    func showLibrary(animated: Bool = true) {
        guard !isShowingLibrary else { return }
        isShowingLibrary = true
        onShowingLibraryChange?(true)
        closeContents()
        closePageField()
        closeSearch()
        desk.abandonSwipe()
        sleep()
        if let window, window.firstResponder !== window { window.makeFirstResponder(nil) }
        showTrafficLights(true, animated: animated)
        Task { await self.flushSpread() }
        guard let host = libraryHost else { return }
        host.isHidden = false
        fade(host, to: 1, animated: animated)
    }

    /// Fades the library away from over the book that's open.
    func showBook(animated: Bool = true) {
        guard isShowingLibrary else { return }
        isShowingLibrary = false
        onShowingLibraryChange?(false)
        showTrafficLights(isFullscreen, animated: animated)
        guard let host = libraryHost else { return }
        fade(host, to: 0, animated: animated) { [weak self] in
            guard let self, !self.isShowingLibrary else { return }
            host.isHidden = true
        }
    }

    private func fade(_ view: NSView, to alpha: CGFloat, animated: Bool, then done: (@MainActor () -> Void)? = nil) {
        let moves = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = moves ? Self.motion : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = alpha
        }, completionHandler: {
            Task { @MainActor in done?() }
        })
    }

    /// What a picture of `book`'s spread shows: the page's own size, styles and columns, and the scale
    /// the picture was taken at.
    private func signature(of image: CGImage, in book: BookWebView) -> String {
        let size = book.frame.size
        let scale = size.width > 0 ? CGFloat(image.width) / size.width : 0
        return LastSpreadCache.signature(
            size: size, scale: scale, columns: book.columns, columnWidth: book.columnWidth, css: book.css)
    }

    /// The look a spread would have in the window now, to match a kept picture against.
    private func spreadSignature() -> String {
        LastSpreadCache.signature(
            size: layout.frame.size, scale: window?.backingScaleFactor ?? 2, columns: layout.columns,
            columnWidth: layout.columnWidth, css: css())
    }

    /// Shows the picture of the spread `book` was left on, if one was kept in the look the window has
    /// now. True if it did.
    @discardableResult
    func showLastSpread(of book: Book) -> Bool {
        guard let spreads else { return false }
        layout = BookFrame(in: desk.bounds.size, settings: settings, fullscreen: isFullscreen)
        guard let image = spreads.image(bookID: book.id, signature: spreadSignature()) else { return false }
        placeholderBookID = book.id
        hint.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeholder.layer?.contents = image
        placeholder.isHidden = false
        // Under the pages, which fade in over it, and under the spine's shadow, as the pages are.
        if let page = session?.book {
            desk.addSubview(placeholder, positioned: .below, relativeTo: page)
        } else {
            desk.addSubview(placeholder, positioned: .below, relativeTo: spine)
        }
        CATransaction.commit()
        placeViews()
        applyColors(animated: false)
        return true
    }

    private func hidePlaceholder() {
        placeholderBookID = nil
        placeholder.isHidden = true
        placeholder.layer?.contents = nil
        placeholder.removeFromSuperview()
        placeViews()
    }

    var isShowingLastSpread: Bool { placeholderBookID != nil }

    /// Keeps a picture of the spread the reader's on, at most once a `spreadInterval`, and soon after
    /// the last place asked for.
    private func rememberSpread() {
        guard spreads != nil, session?.bookID != nil else { return }
        spreadWanted = true
        guard spreadMemory == nil else { return }
        var wait = Duration.zero
        if let last = lastSpreadAttempt { wait = max(.zero, Self.spreadInterval - last.duration(to: .now)) }
        spreadMemory = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            await self?.writeSpread()
            self?.spreadMemory = nil
            if self?.spreadWanted == true { self?.rememberSpread() }
        }
    }

    private func writeSpread() async {
        spreadWanted = false
        lastSpreadAttempt = .now
        // A layout change remembers it once it's over.
        guard let spreads, let session, let bookID = session.bookID, let here = session.book.currentLocation,
              !isLayingOut
        else { return }
        // A resize that hasn't settled may not have reached the pictures yet.
        guard !isResizeSettling else {
            spreadWanted = true
            return
        }
        // A book taken off the shelf while it lay open under the library keeps nothing.
        if session.record != nil, library?.book(id: bookID) == nil { return }
        var image = session.cache.imagesBelong(to: here) ? session.cache.image(for: .current) : nil
        if image == nil {
            // A picture taken mid-curl would be of the wrong page, so it waits for the next chance.
            guard !session.turns.isTurning else {
                spreadWanted = true
                return
            }
            image = await snapshot(of: session.book)
        }
        guard let image, self.session?.book === session.book, session.book.currentLocation?.cfi == here.cfi,
              !isLayingOut, !isResizeSettling
        else { return }
        spreads.save(image, signature: signature(of: image, in: session.book), bookID: bookID)
    }

    /// Takes the picture that's waiting now, and returns once it's written.
    private func flushSpread() async {
        if let memory = spreadMemory {
            memory.cancel()
            await memory.value
        }
        await spreads?.written()
    }

    /// A quiet line along the bottom of the desk that goes by itself.
    func showNotice(_ text: String) {
        notice.stringValue = text
        notice.sizeToFit()
        placeViews()
        fade(notice, to: 1, animated: true)
        noticeFading?.cancel()
        noticeFading = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled, let self else { return }
            self.fade(self.notice, to: 0, animated: true)
        }
    }

    private func show(_ location: ReaderLocation) {
        toolbarModel.timeLeft = TimeLeft.text(minutes: location.chapterMinutesLeft)
        toolbarModel.isMarked = location.isMarked
        placeProgress(location, animated: true)
    }

    /// Nil if there's nowhere to keep places, or the file can't be read.
    private func bookID(of url: URL) async -> String? {
        guard positions != nil else { return nil }
        do {
            return try await BookID.of(url)
        } catch {
            Self.log.error("Reading the book's ID failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Keeping the place

    /// While the book opens or its layout changes, it lands on pages near the reader's place that
    /// aren't where they are, so only the moves made outside those are kept.
    private var isLayingOut: Bool {
        openingBook != nil || restyling != nil || places.isChangingLayout
    }

    private func relocated(to location: ReaderLocation, in book: BookWebView) {
        hideHighlightBar()
        show(location)
        updateRibbon(animated: true)
        if !isLayingOut { keep(location, in: book) }
    }

    /// The reader is at `location` in `book` now: layout changes go back to it, and it's saved under
    /// that book's ID. A place from a book that's no longer the one open is nobody's.
    private func keep(_ location: ReaderLocation, in book: BookWebView) {
        guard let session, session.book === book else { return }
        places.moved(to: location.cfi)
        guard let bookID = session.bookID else { return }
        writer?.save(location, bookID: bookID)
        onRead?(bookID, location)
        rememberSpread()
    }

    /// Returns once the turns, jumps and restyles under way are over and the reader's place is
    /// written, and then the picture of its spread.
    func keepPlace() async {
        await placesKept()
        await flushSpread()
    }

    /// Returns once the turns, jumps and restyles under way are over and the reader's place is
    /// written. The app waits for this as it quits, before the picture of the spread, which can be slow.
    func placesKept() async {
        await session?.turns.landed()
        await jumping?.value
        await restyling?.value
        await writer?.written()
    }

    // MARK: Commands and keys

    func perform(_ command: ReaderCommand) {
        // Over the library, only what's about the window does anything.
        if isShowingLibrary && command != .toggleFullscreen && command != .showLibrary { return }
        switch command {
        case .biggerText, .smallerText:
            var changed = settings
            changed.fontSize = ReaderCommand.fontSize(after: command, from: settings.fontSize)
            change(changed)
        case .toggleFullscreen:
            window?.toggleFullScreen(nil)
        case .showLibrary:
            onShowLibrary?()
        case .toggleTOC:
            toggleContents()
        case .toggleHighlights:
            toggleHighlights()
        case .goToStart:
            jump { await $0.goToStart() }
        case .goToEnd:
            jump { await $0.goToEnd() }
        case .goToPage:
            showPageField()
        case .toggleMarker:
            toggleMarker()
        case .goToMarker:
            guard let marker = bookMarker else { return }
            jump { await $0.go(toCFI: marker.cfi) }
        case .find:
            showSearch()
        }
    }

    // MARK: Search

    /// Opens the search box over the book, with the last search still in it.
    private func showSearch() {
        guard session != nil else { return }
        closeContents()
        closeHighlights()
        closePageField()
        hideHighlightBar()
        searchBox.setTheme(theme)
        if !isSearchShown { searchBox.alphaValue = 0 }
        isSearchShown = true
        searchScrim.frame = desk.bounds
        searchScrim.isHidden = false
        searchBox.isHidden = false
        searchBox.begin(query: searchQuery, outcome: searchOutcome, selected: searchSelection)
        placeSearchBox()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            searchBox.animator().alphaValue = 1
        }
    }

    /// Closes the box without moving. Called again as the field gives up the keyboard, which does
    /// nothing then.
    func closeSearch() {
        guard isSearchShown else { return }
        isSearchShown = false
        searchScrim.isHidden = true
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           (editor.delegate as? NSView)?.isDescendant(of: searchBox) == true {
            window?.makeFirstResponder(nil)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            searchBox.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isSearchShown else { return }
                self.searchBox.isHidden = true
            }
        })
    }

    /// Searches the open book for `query` straight away, and shows what's found. A reply to a search
    /// that's since been replaced, or to another book, is dropped.
    func search(_ query: String) async {
        searchQuery = query
        guard let book = session?.book, SearchResults.isSearchable(query) else {
            searchOutcome = nil
            searchSelection = nil
            searchBox.show(nil, for: query)
            return
        }
        guard let outcome = await book.search(query, limit: SearchResults.limit),
              searchQuery == query, session?.book === book
        else { return }
        searchOutcome = outcome
        searchSelection = nil
        searchBox.show(outcome, for: query)
        searchSelection = searchBox.selected
    }

    /// Closes the box and goes to the match, which glows for a moment once there.
    func pickSearchMatch(at index: Int) {
        guard let matches = searchOutcome?.matches, matches.indices.contains(index) else { return }
        let match = matches[index]
        searchSelection = index
        jump { book in
            let landed = await book.go(toCFI: match.cfi)
            await book.flash(match.cfi)
            return landed
        }
    }

    /// Centred below where the toolbar would be, like the go-to-page field.
    private func placeSearchBox() {
        let height = searchBox.preferredHeight
        searchBox.frame = NSRect(
            x: ((desk.bounds.width - SearchBox.width) / 2).rounded(),
            y: desk.bounds.height - 52 - height,
            width: SearchBox.width, height: height)
        searchScrim.frame = desk.bounds
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil, !isShowingLibrary,
              let action = KeyAction.of(
                key: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags,
                isRepeat: event.isARepeat, isFullscreen: isFullscreen, isTyping: window.firstResponder is NSText,
                isInContents: isContentsShown || isHighlightsShown)
        else {
            // Esc puts the bar away.
            if event.keyCode == 53, !highlightBar.isHidden, event.window === window {
                hideHighlightBar()
                return true
            }
            return false
        }
        switch action {
        case let .command(command):
            perform(command)
        case let .turn(direction, isRepeat):
            guard session != nil else { return false }
            turn(direction, isRepeat: isRepeat)
        case .leaveFullscreen:
            window.toggleFullScreen(nil)
        case .closeContents:
            closeContents()
            closeHighlights()
        case .ignore:
            break
        }
        return true
    }

    func turn(_ direction: TurnDirection, isRepeat: Bool = false) {
        guard !isCovered, let session else { return }
        places.turned()
        turnBegan()
        session.turns.turn(direction, isRepeat: isRepeat)
        watchTurnLanding()
    }

    // MARK: Jumps

    /// Takes the book somewhere new with no curl, once the turns before it have landed. A jump is a
    /// new place, so it counts as a turn when it's asked for and again when it lands: a restyle won't
    /// take the reader back to a place captured before it landed.
    private func jump(_ go: @escaping (BookWebView) async -> ReaderLocation?) {
        guard let session else { return }
        closeContents()
        closePageField()
        closeSearch()
        places.turned()
        jumping = Task { [weak self] in
            _ = await session.turns.jump { await go(session.book) }
            self?.places.turned()
        }
    }

    /// Goes to the page typed into the field and closes it. False, leaving it open, if what was typed
    /// isn't a page number.
    @discardableResult
    func goToPage(typed: String) -> Bool {
        guard let here = session?.book.currentLocation,
              let page = GoToPage.page(forTyped: typed, pageCount: here.pageCount)
        else { return false }
        jump { await $0.go(toPage: page) }
        return true
    }

    /// Closes the contents and goes to the chapter. A link the book can't follow just now is found by
    /// how far through the book it is, and one with no place in the book goes nowhere.
    func choose(_ entry: TOCEntry) {
        guard let fraction = entry.fraction else { return }
        jump { book in
            switch await book.go(toHref: entry.href) {
            case let .went(landed): landed
            case .unresolved: await book.go(toFraction: fraction)
            }
        }
    }

    private func showPageField() {
        guard let here = session?.book.currentLocation, here.pageCount > 0 else { return }
        closeContents()
        closeSearch()
        placeViews()
        pageField.setTheme(theme)
        if !isPageFieldShown { pageField.alphaValue = 0 }
        isPageFieldShown = true
        pageField.isHidden = false
        pageField.begin(page: here.page, pageCount: here.pageCount)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageField.animator().alphaValue = 1
        }
    }

    /// Closes the field without moving. Called again as the field gives up the keyboard, which does
    /// nothing then.
    func closePageField() {
        guard isPageFieldShown else { return }
        isPageFieldShown = false
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           (editor.delegate as? NSView)?.isDescendant(of: pageField) == true {
            window?.makeFirstResponder(nil)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageField.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isPageFieldShown else { return }
                self.pageField.isHidden = true
            }
        })
    }

    // MARK: Contents

    /// A book with no contents has nothing to show, so this does nothing for it.
    private func toggleContents() {
        if isContentsShown {
            closeContents()
            return
        }
        guard let session, session.book.isBookOpen else { return }
        contentsLoading?.cancel()
        contentsLoading = Task { [weak self] in
            guard let self else { return }
            let entries: [TOCEntry]
            if let known = self.tableOfContents {
                entries = known
            } else {
                entries = await session.book.toc()
                guard !Task.isCancelled, self.session?.book === session.book else { return }
                self.tableOfContents = entries
            }
            guard !Task.isCancelled, !entries.isEmpty else { return }
            self.openContents(entries, at: session.book.currentLocation?.fraction ?? 0)
        }
    }

    /// Slides the contents in over the left of the book, with the keyboard theirs.
    private func openContents(_ entries: [TOCEntry], at fraction: Double) {
        closePageField()
        closeSearch()
        closeHighlights()
        hideHighlightBar()
        isContentsShown = true
        contents.setTheme(theme)
        contents.show(entries, at: fraction)
        contents.frame = contentsFrame(shown: false)
        contents.isHidden = false
        contentsScrim.frame = desk.bounds
        contentsScrim.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contents.animator().frame = contentsFrame(shown: true)
        }
        contents.focus()
    }

    private func closeContents() {
        contentsLoading?.cancel()
        guard isContentsShown else { return }
        isContentsShown = false
        contentsScrim.isHidden = true
        if contents.hasFocus { window?.makeFirstResponder(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contents.animator().frame = contentsFrame(shown: false)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isContentsShown else { return }
                self.contents.isHidden = true
            }
        })
    }

    private func contentsFrame(shown: Bool) -> NSRect {
        NSRect(x: shown ? 0 : -TOCSidebar.width, y: 0, width: TOCSidebar.width, height: desk.bounds.height)
    }

    private func contentsPlace(of event: NSEvent) -> ScrollRoute.Contents {
        guard isContentsShown || isHighlightsShown else { return .closed }
        let point = desk.convert(event.locationInWindow, from: nil)
        return contents.frame.contains(point) || highlightsPanel.frame.contains(point) ? .under : .beside
    }

    // MARK: Highlights

    /// The colour a highlight is drawn in: a warm yellow, a little deeper on the night page. Yellow
    /// disappears into the sepia page, so that one gets a soft blue.
    static func highlightColor(_ theme: Theme) -> String {
        switch theme {
        case .paper: "#f2c744"
        case .sepia: "#4f9fd0"
        case .night: "#d9a63a"
        }
    }

    private var highlightStore: HighlightStore? { library?.highlights }

    /// The reader selected words, or let go of them.
    private func selectionChanged(_ info: BookWebView.SelectionInfo?) {
        guard let info else {
            // A click on a highlight collapses the selection just after it's shown the bar.
            if let shown = barShownAt, targetedHighlight != nil, shown.duration(to: .now) < .milliseconds(400) { return }
            hideHighlightBar()
            return
        }
        guard highlightStore != nil, session?.bookID != nil, !isContentsShown, !isHighlightsShown else { return }
        selection = info
        if bookHighlights.contains(where: { $0.cfi == info.cfi }) {
            targetedHighlight = info.cfi
            showHighlightBar(.remove, at: info.rect)
        } else {
            targetedHighlight = nil
            showHighlightBar(.add, at: info.rect)
        }
    }

    private func highlightClicked(_ cfi: String, rect: CGRect) {
        guard !isContentsShown, !isHighlightsShown else { return }
        selection = nil
        targetedHighlight = cfi
        showHighlightBar(.remove, at: rect)
    }

    /// `rect` is on the page, from its top left. The bar goes by it, in the desk.
    private func showHighlightBar(_ mode: HighlightBar.Mode, at rect: CGRect) {
        guard let book = session?.book else { return }
        let target = CGRect(
            x: book.frame.minX + rect.minX,
            y: book.frame.minY + book.bounds.height - rect.maxY,
            width: rect.width, height: rect.height)
        highlightBar.setTheme(theme)
        highlightBar.show(mode)
        highlightBar.frame = HighlightBar.frame(for: target, in: desk.bounds)
        highlightBar.isHidden = false
        barShownAt = .now
    }

    private func hideHighlightBar() {
        highlightBar.isHidden = true
        selection = nil
        targetedHighlight = nil
        barShownAt = nil
    }

    private func pressedBar(_ mode: HighlightBar.Mode) {
        switch mode {
        case .add:
            guard let info = selection else { return }
            addHighlight(from: info)
        case .remove:
            guard let cfi = targetedHighlight, let highlight = bookHighlights.first(where: { $0.cfi == cfi }) else {
                return hideHighlightBar()
            }
            remove(highlight)
        }
    }

    private func addHighlight(from info: BookWebView.SelectionInfo) {
        guard let session, let bookID = session.bookID, let store = highlightStore else { return }
        hideHighlightBar()
        let highlight = Highlight(
            cfi: info.cfi, text: info.text, chapterTitle: info.chapterTitle, fraction: info.fraction)
        Task { [weak self] in
            await store.add(highlight, bookID: bookID)
            await session.book.addHighlight(info.cfi)
            await session.book.clearSelection()
            await self?.highlightsChanged(bookID: bookID, in: session.book)
        }
    }

    private func remove(_ highlight: Highlight) {
        guard let session, let bookID = session.bookID, let store = highlightStore else { return }
        hideHighlightBar()
        Task { [weak self] in
            await store.remove(id: highlight.id, bookID: bookID)
            await session.book.removeHighlight(highlight.cfi)
            await self?.highlightsChanged(bookID: bookID, in: session.book)
        }
    }

    /// Reads the book's highlights again, and has the curl's pictures redrawn with them.
    private func highlightsChanged(bookID: String, in book: BookWebView) async {
        guard let store = highlightStore else { return }
        let marks = await store.highlights(bookID: bookID)
        guard session?.book === book else { return }
        bookHighlights = marks
        if isHighlightsShown { highlightsPanel.show(marks) }
        if let here = book.currentLocation { await session?.cache.refresh(around: here) }
        rememberSpread()
    }

    /// The reader changed theme: the highlights are redrawn in its colour.
    private func recolorHighlights() {
        guard let book = session?.book, book.isBookOpen, !bookHighlights.isEmpty else { return }
        let color = Self.highlightColor(theme)
        guard color != book.highlightColor else { return }
        Task { [weak self] in
            await book.setHighlights(book.highlightCFIs, color: color)
            guard let self, self.session?.book === book, let here = book.currentLocation else { return }
            await self.session?.cache.refresh(around: here)
        }
    }

    /// Goes to the highlight.
    func choose(_ highlight: Highlight) {
        jump { await $0.go(toCFI: highlight.cfi) }
    }

    private func toggleHighlights() {
        if isHighlightsShown {
            closeHighlights()
            return
        }
        guard let session, session.book.isBookOpen, let bookID = session.bookID, let store = highlightStore else { return }
        Task { [weak self] in
            let marks = await store.highlights(bookID: bookID)
            guard let self, self.session?.book === session.book else { return }
            self.bookHighlights = marks
            self.openHighlights(marks)
        }
    }

    private func openHighlights(_ marks: [Highlight]) {
        closePageField()
        closeSearch()
        closeContents()
        hideHighlightBar()
        isHighlightsShown = true
        highlightsPanel.setTheme(theme)
        highlightsPanel.show(marks)
        highlightsPanel.frame = contentsFrame(shown: false)
        highlightsPanel.isHidden = false
        contentsScrim.frame = desk.bounds
        contentsScrim.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlightsPanel.animator().frame = contentsFrame(shown: true)
        }
        highlightsPanel.focus()
    }

    private func closeHighlights() {
        guard isHighlightsShown else { return }
        isHighlightsShown = false
        contentsScrim.isHidden = true
        if highlightsPanel.hasFocus { window?.makeFirstResponder(nil) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlightsPanel.animator().frame = contentsFrame(shown: false)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isHighlightsShown else { return }
                self.highlightsPanel.isHidden = true
            }
        })
    }

    // MARK: Reading marker

    /// The ribbon's colour: a muted red on the paper and sepia pages, softer on the night page.
    static func ribbonColor(_ theme: Theme) -> NSColor {
        switch theme {
        case .paper: NSColor(srgbRed: 0.69, green: 0.23, blue: 0.20, alpha: 1)
        case .sepia: NSColor(srgbRed: 0.62, green: 0.24, blue: 0.18, alpha: 1)
        case .night: NSColor(srgbRed: 0.62, green: 0.34, blue: 0.32, alpha: 1)
        }
    }

    private func setBookMarker(_ marker: Marker?) {
        bookMarker = marker
        onMarkerChange?(marker != nil)
    }

    /// Marks the spread on show, moving the marker if it was elsewhere, or takes it away if this is
    /// the spread that holds it.
    private func toggleMarker() {
        guard let session, session.book.isBookOpen, let bookID = session.bookID, let store = library?.markers,
              let here = session.book.currentLocation
        else { return }
        let book = session.book
        let previous = marking
        marking = Task { [weak self] in
            await previous?.value
            await session.turns.landed()
            guard let self, self.session?.book === book else { return }
            if book.currentLocation?.isMarked == true {
                await store.remove(bookID: bookID)
                await book.setMarker(nil)
                guard self.session?.book === book else { return }
                self.setBookMarker(nil)
                self.showNotice("Marker removed")
            } else {
                let at = book.currentLocation ?? here
                let place = await book.place() ?? at.cfi
                guard let cfi = await book.setMarker(place) else { return }
                let marker = Marker(cfi: cfi, fraction: at.fraction, page: at.page, chapterTitle: at.chapterTitle)
                await store.set(marker, bookID: bookID)
                guard self.session?.book === book else { return }
                self.setBookMarker(marker)
                self.showNotice("Marked page \(at.page)")
            }
            if let here = book.currentLocation { self.show(here) }
            self.updateRibbon(animated: true)
        }
    }

    /// A page is about to turn: the ribbon leaves it until the turn has landed.
    private func turnBegan() {
        turnWatch?.cancel()
        isTurning = true
        updateRibbon(animated: false)
    }

    /// Shows the ribbon again, if the spread it lands on holds the marker, once every turn has landed.
    private func watchTurnLanding() {
        guard let turns = session?.turns else { return }
        turnWatch?.cancel()
        turnWatch = Task { [weak self] in
            await turns.landed()
            guard !Task.isCancelled, let self else { return }
            self.isTurning = false
            self.updateRibbon(animated: true)
        }
    }

    private func updateRibbon(animated: Bool) {
        let on = !isTurning && session?.book.isBookOpen == true && session?.book.currentLocation?.isMarked == true
        toolbarModel.isMarked = session?.book.currentLocation?.isMarked == true
        guard on != isRibbonOn else { return }
        isRibbonOn = on
        fade(ribbon, to: on ? 1 : 0, animated: animated)
    }

    // MARK: For tests

    var location: ReaderLocation? { session?.book.currentLocation }
    var deskView: NSView { desk }
    /// The curl's images around the place, once the cache has made them.
    func spreadImages() async -> [CGImage] {
        guard let session else { return [] }
        await session.cache.neighboursReady()
        return [SpreadSlot.current, .next, .previous].compactMap { session.cache.image(for: $0) }
    }
    /// How many times a book has begun loading.
    private(set) var loadsStarted = 0
    var book: BookWebView? { session?.book }
    var layoutColumns: Int { layout.columns }
    var isShowingContents: Bool { isContentsShown }
    var isShowingPageField: Bool { isPageFieldShown }
    var isShowingHighlights: Bool { isHighlightsShown }
    var highlightsShown: [Highlight] { highlightsPanel.highlights }
    func pressHighlightBar() { highlightBar.press() }
    var highlightBarMode: HighlightBar.Mode? { highlightBar.isHidden ? nil : highlightBar.mode }
    var contentsEntries: [TOCEntry] { contents.entries }
    var marker: Marker? { bookMarker }
    var isRibbonShown: Bool { isRibbonOn }
    var noticeText: String { notice.stringValue }

    /// Returns once the contents have been read and the restyles and jumps under way are done.
    func settled() async {
        await resizeSettling?.value
        await contentsLoading?.value
        await restyling?.value
        await jumping?.value
        await restyling?.value
        await marking?.value
    }

    // MARK: Settings and layout

    func change(_ changed: ReaderSettings) {
        guard changed != settings else { return }
        settings = changed
        settings.save(defaults)
        if toolbarModel.settings != settings { toolbarModel.settings = settings }
        restyle(animated: true)
    }

    /// Where the reader is, or the spread shown before anything's known.
    private var place: String? {
        places.place(showing: session?.book.currentLocation?.cfi)
    }

    private var theme: Theme {
        let isDark = desk.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return settings.resolvedTheme(systemIsDark: isDark)
    }

    private func css() -> String {
        ReadingCSS.css(settings, theme: theme, fullscreen: isFullscreen)
    }

    /// Lays the book out for the settings, theme and window as they are now, then refreshes the
    /// curl's images. `animated` crossfades from the old look over 200 ms.
    /// `returningTo` is a place captured earlier, as a resize or fullscreen does when it starts.
    /// Otherwise it's where the book is now.
    private func restyle(animated: Bool, returningTo capture: PlaceKeeper.Capture? = nil) {
        restyleWanted = true
        restyleAnimated = restyleAnimated || animated
        restyleCapture = restyleCapture ?? capture ?? places.capture(place)
        guard restyling == nil else { return }
        restyling = Task { [weak self] in
            while let self, self.restyleWanted {
                self.restyleWanted = false
                let animated = self.restyleAnimated
                let capture = self.restyleCapture
                self.restyleAnimated = false
                self.restyleCapture = nil
                await self.applyLayout(animated: animated, returningTo: capture)
            }
            self?.restyling = nil
        }
    }

    private func applyLayout(animated: Bool, returningTo capture: PlaceKeeper.Capture?) async {
        layout = BookFrame(in: desk.bounds.size, settings: settings, fullscreen: isFullscreen)
        let css = css()
        guard let session, session.book.isBookOpen else {
            placeViews()
            applyColors(animated: animated)
            return
        }
        let book = session.book
        let restyles = book.css != css || book.columns != layout.columns || book.columnWidth != layout.columnWidth
        if restyles && animated { await coverBook(session) }
        placeViews()
        if restyles {
            await book.applyStyles(css: css, columns: layout.columns, columnWidth: layout.columnWidth)
        }
        // Read after the restyle, so a page turned meanwhile is kept.
        if let cfi = places.target(capture), book.currentLocation?.cfi != cfi {
            _ = await book.go(toCFI: cfi)
        }
        if restyles && animated {
            await book.settle()
            await painted(book)
        }
        applyColors(animated: animated)
        uncoverBook()
        // A book opened meanwhile has its own place to show.
        if self.session?.book === book, let here = book.currentLocation {
            show(here)
            // A page turned while the layout changed is where the reader now is.
            if places.hasTurned(since: capture) { keep(here, in: book) }
            await session.cache.refresh(around: here)
            rememberSpread()
        }
    }

    /// Lays the old look over the book, so the new one can arrive behind it and fade in.
    private func coverBook(_ session: Session) async {
        session.curl.end()
        let here = session.book.currentLocation
        var image = here.flatMap { session.cache.imagesBelong(to: $0) ? session.cache.image(for: .current) : nil }
        if image == nil { image = await snapshot(of: session.book) }
        guard let image else { return }
        isCovered = true
        cover.frame = session.book.frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.layer?.contents = image
        cover.layer?.opacity = 1
        cover.isHidden = false
        CATransaction.commit()
    }

    private func uncoverBook() {
        guard isCovered else { return }
        isCovered = false
        let layer = cover.layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, !self.isCovered else { return }
            self.cover.isHidden = true
            self.cover.layer?.contents = nil
        }
        animate(layer, "opacity", to: Float(0))
        CATransaction.commit()
    }

    /// Returns once the web view has what it's been given on screen, or soon after if it can't say.
    private func painted(_ book: BookWebView) async {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        configuration.snapshotWidth = 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = OneShot(continuation)
            book.webView.takeSnapshot(with: configuration) { _, _ in wait.finish() }
            Task {
                try? await Task.sleep(for: Self.paintTimeout)
                wait.finish()
            }
        }
    }

    private func snapshot(of book: BookWebView) async -> CGImage? {
        await withCheckedContinuation { continuation in
            book.webView.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// Puts the book, its curl and the spine where the layout says, at once.
    private func placeViews() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desk.bookFrame = layout.frame
        if let session {
            session.book.frame = layout.frame
            session.curl.frame = layout.frame
        }
        spine.frame = layout.frame
        ribbon.frame = MarkerRibbon.frame(in: layout.frame)
        spine.isHidden = layout.columns != 2 || (session == nil && placeholderBookID == nil)
        placeholder.frame = layout.frame
        if isContentsShown {
            contents.frame = contentsFrame(shown: true)
            contentsScrim.frame = desk.bounds
        }
        if isHighlightsShown {
            highlightsPanel.frame = contentsFrame(shown: true)
            contentsScrim.frame = desk.bounds
        }
        hideHighlightBar()
        // Below the toolbar, where it would be if it were awake.
        if isSearchShown { placeSearchBox() }
        pageField.frame = NSRect(
            x: ((desk.bounds.width - GoToPageField.size.width) / 2).rounded(),
            y: desk.bounds.height - 52 - GoToPageField.size.height,
            width: GoToPageField.size.width, height: GoToPageField.size.height)
        notice.frame.origin = NSPoint(
            x: ((desk.bounds.width - notice.frame.width) / 2).rounded(), y: max(8, (layout.frame.minY - notice.frame.height) / 2).rounded())
        hint.sizeToFit()
        hint.frame.origin = NSPoint(
            x: ((desk.bounds.width - hint.frame.width) / 2).rounded(),
            y: ((desk.bounds.height - hint.frame.height) / 2).rounded())
        if let location = session?.book.currentLocation {
            placeProgress(location, animated: false)
        } else {
            progressBar.frame = NSRect(x: 0, y: 0, width: 0, height: 1)
        }
        CATransaction.commit()
    }

    /// The hairline runs along the bottom of the desk, full at the end of the book.
    private func placeProgress(_ location: ReaderLocation, animated: Bool) {
        let share = location.isAtEnd ? 1 : min(1, max(0, location.fraction))
        let width = (desk.bounds.width * share).rounded()
        let target = NSRect(x: 0, y: 0, width: width, height: 1)
        guard animated else {
            progressBar.frame = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.motion
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            progressBar.animator().frame = target
        }
    }

    /// The desk, spine, hairline, toolbar and back of a single turning page take the theme's colours.
    private func applyColors(animated: Bool) {
        let theme = theme
        let colors = ReadingCSS.colors(theme)
        toolbarModel.theme = theme
        contents.setTheme(theme)
        highlightsPanel.setTheme(theme)
        highlightBar.setTheme(theme)
        recolorHighlights()
        pageField.setTheme(theme)
        searchBox.setTheme(theme)
        ribbon.color = Self.ribbonColor(theme)
        session?.turns.pageColor = colors.page.cgColor
        session?.curl.spineColor = layout.columns == 2 ? colors.spine.cgColor : nil
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            animate(desk.layer, "backgroundColor", to: colors.desk.cgColor)
            animate(progressBar.layer, "backgroundColor", to: colors.soft.cgColor)
        } else {
            desk.layer?.backgroundColor = colors.desk.cgColor
            progressBar.layer?.backgroundColor = colors.soft.cgColor
        }
        spine.setColor(colors.spine.cgColor, animated: animated)
        CATransaction.commit()
    }

    /// Changes a layer property with the app's ease-out over 200 ms.
    private func animate(_ layer: CALayer?, _ keyPath: String, to value: Any) {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        animation.toValue = value
        animation.duration = Self.motion
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.setValue(value, forKeyPath: keyPath)
        layer.add(animation, forKey: keyPath)
    }

    // MARK: Window

    func windowDidResize(_ notification: Notification) {
        // A resize nobody's dragging, such as zooming, is a layout change too, and the book's landings
        // during it aren't the reader's moves.
        if !places.isChangingLayout {
            places.beginLayoutChange(at: place)
            isResizeOwnChange = true
        }
        let wanted = BookFrame(in: desk.bounds.size, settings: settings, fullscreen: isFullscreen)
        // A change in the number of pages can't wait for the window to stop, or two columns would
        // squeeze onto one page.
        // Restyles during a live resize or fullscreen transition go back to where it began.
        if wanted.columns != layout.columns {
            restyle(animated: false, returningTo: places.layoutChangeCapture)
        } else {
            layout = wanted
            placeViews()
        }
        resizeSettling?.cancel()
        isResizeSettling = true
        resizeSettling = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeQuiet)
            guard !Task.isCancelled, let self else { return }
            self.isResizeSettling = false
            if self.isResizeOwnChange {
                self.endLayoutChange()
            } else {
                self.restyle(animated: false, returningTo: self.places.layoutChangeCapture)
            }
        }
    }

    /// A live resize or fullscreen transition takes over a resize that's still settling, and its place.
    private func beginLayoutChange() {
        places.beginLayoutChange(at: place)
        isResizeOwnChange = false
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        beginLayoutChange()
    }

    /// The change is over, whether or not the size changed, so its place is used now or never.
    func windowDidEndLiveResize(_ notification: Notification) {
        endLayoutChange()
    }

    private func endLayoutChange() {
        isResizeOwnChange = false
        guard places.isChangingLayout else { return }
        resizeSettling?.cancel()
        isResizeSettling = false
        restyle(animated: false, returningTo: places.endLayoutChange())
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        beginLayoutChange()
        isFullscreen = true
        toolbarModel.isFullscreen = true
        showTrafficLights(true, animated: false)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        endLayoutChange()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        beginLayoutChange()
        isFullscreen = false
        toolbarModel.isFullscreen = false
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        endLayoutChange()
        showTrafficLights(isShowingLibrary, animated: true)
    }

    /// A transition that doesn't happen leaves the window as it was, and its text size with it.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isFullscreen = false
        toolbarModel.isFullscreen = false
        endLayoutChange()
        showTrafficLights(isShowingLibrary, animated: true)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        isFullscreen = true
        toolbarModel.isFullscreen = true
        endLayoutChange()
    }

    /// Monitors would keep acting for a window that's gone. `show` puts them back.
    func windowWillClose(_ notification: Notification) {
        for monitor in [keyMonitor, scrollMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        scrollMonitor = nil
    }

    /// The end of a gesture may never reach a window that's lost the keyboard, and no page should stay
    /// held up for that.
    func windowDidResignKey(_ notification: Notification) {
        desk.abandonSwipe()
        sleep()
    }

    // MARK: Waking and sleeping

    private func wake() {
        let now = ProcessInfo.processInfo.systemUptime
        idle.activity(at: now)
        setAwake(true)
        idleCheck?.cancel()
        idleCheck = Task { [weak self, idle] in
            try? await Task.sleep(for: .seconds(idle.delay))
            guard !Task.isCancelled, let self else { return }
            if self.isOverToolbar {
                self.wake()
            } else if !self.idle.isAwake(at: ProcessInfo.processInfo.systemUptime) {
                self.setAwake(false)
            }
        }
    }

    private func sleep() {
        idle.sleep()
        idleCheck?.cancel()
        setAwake(false)
    }

    private func setAwake(_ awake: Bool) {
        guard toolbarModel.isAwake != awake else { return }
        toolbarModel.isAwake = awake
        if !awake && isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    /// True if a pointer at `point` on the desk is over the title bar's strip along its top.
    /// In fullscreen they're the system's, shown in its reveal bar, so they're always left visible.
    static func showsTrafficLights(
        at point: NSPoint, in bounds: NSRect, titleBarHeight: CGFloat, isFullscreen: Bool = false
    ) -> Bool {
        if isFullscreen { return true }
        return titleBarHeight > 0 && bounds.contains(point) && point.y >= bounds.maxY - titleBarHeight
    }

    private func followPointer(to point: NSPoint) {
        guard let window else { return }
        let titleBar = desk.bounds.height - window.contentLayoutRect.height
        let visible = Self.showsTrafficLights(
            at: point, in: desk.bounds, titleBarHeight: titleBar, isFullscreen: isFullscreen)
        showTrafficLights(visible, animated: true)
    }

    /// The close, minimise and zoom buttons show only while the pointer's in the title bar's strip.
    private func showTrafficLights(_ visible: Bool, animated: Bool) {
        guard visible != areTrafficLightsShown,
              let buttons = window?.standardWindowButton(.closeButton)?.superview
        else { return }
        areTrafficLightsShown = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.motion : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            buttons.animator().alphaValue = visible ? 1 : 0
        }
    }
}

/// Lies over the desk while the contents are open, so a click beside them closes them and turns no page.
private final class ContentsScrim: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// A plain layer-backed view that never takes the mouse.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
