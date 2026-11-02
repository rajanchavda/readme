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
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate {
    /// One open book and everything turning its pages. Each book gets a new one.
    private struct Session {
        let book: BookWebView
        let curl: CurlView
        let cache: SpreadCache
        let turns: TurnCoordinator
    }

    var onShowLibrary: (() -> Void)?

    /// The mockup's stage, which makes the book the size the curl was approved at.
    private static let contentSize = NSSize(width: 1048, height: 620)
    /// Narrow enough for one page, wide enough for the toolbar.
    private static let minimumSize = NSSize(width: 640, height: 420)
    private static let motion = 0.2
    /// How long the window has to keep its size before the curl's images are made again.
    private static let resizeQuiet: Duration = .milliseconds(150)
    private static let paintTimeout: Duration = .milliseconds(500)
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "ReaderWindowController")

    private let desk: DeskView
    private let cover = PassThroughView()
    private let spine = SpineView()
    private let progressBar = PassThroughView()
    private let hint: NSTextField
    private let toolbarModel: ReaderToolbarModel
    private let toolbar: ReaderToolbarHost

    private var settings: ReaderSettings
    private var session: Session?
    private var layout: BookFrame
    private var isFullscreen = false
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var opening: Task<Void, Never>?

    /// Restyles run one at a time, and those asked for while one runs are folded into the next.
    private var restyling: Task<Void, Never>?
    private var restyleWanted = false
    private var restyleAnimated = false
    /// Where the queued restyle goes back to, captured before the change it's for began.
    private var restyleCapture: PlaceKeeper.Capture?
    private var places = PlaceKeeper()
    private var resizeSettling: Task<Void, Never>?
    /// Pages don't turn while the old look covers the book.
    private var isCovered = false

    private var idle = IdleTimer()
    private var idleCheck: Task<Void, Never>?
    private var isOverToolbar = false
    private var areTrafficLightsShown = true

    init() {
        settings = ReaderSettings.load()
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
        window.contentView = desk

        hint = NSTextField(labelWithString: "Press ⌘O to open a book")
        hint.textColor = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 0.7)
        hint.font = .systemFont(ofSize: 15)

        toolbarModel = ReaderToolbarModel(settings: settings)
        toolbar = ReaderToolbarHost(model: toolbarModel)
        super.init(window: window)

        for view in [cover, spine, progressBar] { view.wantsLayer = true }
        cover.isHidden = true
        desk.addSubview(spine)
        desk.addSubview(hint)
        desk.addSubview(progressBar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        desk.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.centerXAnchor.constraint(equalTo: desk.centerXAnchor),
            toolbar.topAnchor.constraint(equalTo: desk.topAnchor, constant: 12),
        ])

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
            if case .start = signal { self.places.turned() }
            session.turns.follow(signal)
        }
        desk.chrome = [toolbar]
        desk.onMouseMoved = { [weak self] point in
            self?.wake()
            self?.followPointer(to: point)
        }
        desk.onMouseExited = { [weak self] in
            self?.sleep()
            self?.showTrafficLights(false, animated: true)
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
            guard let self, let window = self.window else { return event }
            let route = ScrollRoute(isOurWindow: event.window === window, hasSheet: window.attachedSheet != nil)
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

    func chooseBook() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.open(url, at: nil) }
        }
    }

    /// Opens a book at `cfi`, or at its start. `Book` replaces the URL once the library arrives.
    func open(_ url: URL, at cfi: String?) async {
        opening?.cancel()
        session?.curl.end()
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()
        cover.removeFromSuperview()

        layout = BookFrame(in: desk.bounds.size, settings: settings, fullscreen: isFullscreen)
        let book = BookWebView(frame: layout.frame)
        let curl = CurlView(frame: layout.frame)
        // Shown once it has the book, so an empty white page never flashes up.
        book.alphaValue = 0
        // The spine's shadow belongs to the pages, so it lies on the book and the cover, and the
        // turning page passes over it. The curl draws its own on the pages beneath.
        desk.addSubview(book, positioned: .below, relativeTo: spine)
        desk.addSubview(cover, positioned: .above, relativeTo: book)
        desk.addSubview(curl, positioned: .above, relativeTo: spine)
        let cache = SpreadCache(visible: book)
        let turns = TurnCoordinator(book: book, cache: cache, curl: curl)
        session = Session(book: book, curl: curl, cache: cache, turns: turns)
        book.onRelocate = { [weak self] location in self?.show(location) }
        hint.isHidden = true
        placeViews()
        applyColors(animated: false)

        let opening = Task { [weak self] in
            do {
                guard let self else { return }
                await book.applyStyles(css: self.css(), columns: self.layout.columns, columnWidth: self.layout.columnWidth)
                let location = try await book.open(url, at: cfi)
                guard !Task.isCancelled, self.session?.book === book else { return }
                self.window?.title = url.deletingPathExtension().lastPathComponent
                self.show(location)
                await book.settle()
                guard !Task.isCancelled else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = Self.motion
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    book.animator().alphaValue = 1
                }, completionHandler: nil)
                if let here = book.currentLocation { await cache.refresh(around: here) }
            } catch {
                Self.log.error("Opening failed: \(String(describing: error), privacy: .public)")
                guard !Task.isCancelled else { return }
                self?.showFailure(of: url)
            }
        }
        self.opening = opening
        await opening.value
    }

    private func showFailure(of url: URL) {
        session?.book.removeFromSuperview()
        session?.curl.removeFromSuperview()
        session = nil
        toolbarModel.timeLeft = nil
        hint.stringValue = "\(url.lastPathComponent) couldn't be opened"
        hint.isHidden = false
        placeViews()
    }

    private func show(_ location: ReaderLocation) {
        toolbarModel.timeLeft = TimeLeft.text(minutes: location.chapterMinutesLeft)
        placeProgress(location, animated: true)
    }

    // MARK: Commands and keys

    func perform(_ command: ReaderCommand) {
        switch command {
        case .biggerText, .smallerText:
            var changed = settings
            changed.fontSize = ReaderCommand.fontSize(after: command, from: settings.fontSize)
            change(changed)
        case .toggleFullscreen:
            window?.toggleFullScreen(nil)
        case .showLibrary:
            onShowLibrary?()
        case .toggleTOC, .goToStart, .goToEnd, .goToPage:
            // The table of contents and the jumps arrive with Task 10.
            break
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              let action = KeyAction.of(
                key: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode, modifiers: event.modifierFlags,
                isRepeat: event.isARepeat, isFullscreen: isFullscreen, isTyping: window.firstResponder is NSText)
        else { return false }
        switch action {
        case let .command(command):
            perform(command)
        case let .turn(direction, isRepeat):
            guard session != nil else { return false }
            turn(direction, isRepeat: isRepeat)
        case .leaveFullscreen:
            window.toggleFullScreen(nil)
        case .ignore:
            break
        }
        return true
    }

    private func turn(_ direction: TurnDirection, isRepeat: Bool = false) {
        guard !isCovered, let session else { return }
        places.turned()
        session.turns.turn(direction, isRepeat: isRepeat)
    }

    // MARK: Settings and layout

    private func change(_ changed: ReaderSettings) {
        guard changed != settings else { return }
        settings = changed
        settings.save()
        if toolbarModel.settings != settings { toolbarModel.settings = settings }
        restyle(animated: true)
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
        restyleCapture = restyleCapture ?? capture ?? places.capture(session?.book.currentLocation?.cfi)
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
            await session.cache.refresh(around: here)
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
        spine.isHidden = layout.columns != 2 || session == nil
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
        resizeSettling = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeQuiet)
            guard !Task.isCancelled, let self else { return }
            self.restyle(animated: false, returningTo: self.places.layoutChangeCapture)
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        places.beginLayoutChange(at: session?.book.currentLocation?.cfi)
    }

    /// The change is over, whether or not the size changed, so its place is used now or never.
    func windowDidEndLiveResize(_ notification: Notification) {
        endLayoutChange()
    }

    private func endLayoutChange() {
        guard places.isChangingLayout else { return }
        resizeSettling?.cancel()
        restyle(animated: false, returningTo: places.endLayoutChange())
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        places.beginLayoutChange(at: session?.book.currentLocation?.cfi)
        isFullscreen = true
        toolbarModel.isFullscreen = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        endLayoutChange()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        places.beginLayoutChange(at: session?.book.currentLocation?.cfi)
        isFullscreen = false
        toolbarModel.isFullscreen = false
        NSCursor.setHiddenUntilMouseMoves(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        endLayoutChange()
    }

    /// A transition that doesn't happen leaves the window as it was, and its text size with it.
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isFullscreen = false
        toolbarModel.isFullscreen = false
        endLayoutChange()
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
    static func showsTrafficLights(at point: NSPoint, in bounds: NSRect, titleBarHeight: CGFloat) -> Bool {
        titleBarHeight > 0 && bounds.contains(point) && point.y >= bounds.maxY - titleBarHeight
    }

    private func followPointer(to point: NSPoint) {
        guard let window else { return }
        let titleBar = desk.bounds.height - window.contentLayoutRect.height
        showTrafficLights(Self.showsTrafficLights(at: point, in: desk.bounds, titleBarHeight: titleBar), animated: true)
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

/// A plain layer-backed view that never takes the mouse.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
