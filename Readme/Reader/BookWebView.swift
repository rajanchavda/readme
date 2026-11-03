import AppKit
import OSLog
import WebKit

enum BookWebViewError: Error, Equatable {
    case unreadable
    case openFailed(String)
    case javaScript(String)
    case timedOut
    case superseded
}

/// Shows one EPUB, paginated by foliate-js in a `WKWebView`.
///
/// To use it offscreen, host it in a window: `webView` is exposed for `takeSnapshot`. It keeps
/// working in a window that isn't on screen, although WebKit slows the page's timers there.
///
/// `next()`, `previous()` and the `go` methods return the new location, or nil if nothing moved.
/// They run in the order they're called, so turns fired quickly are all honoured.
/// `onRelocate` hears each settled location once, whatever caused it, and not the stops on the way.
/// Parts of the reader that have to follow the book, whoever moves it, add a relocation listener,
/// which hears the same and leaves `onRelocate` to the window.
@MainActor
final class BookWebView: NSView {
    var onRelocate: ((ReaderLocation) -> Void)?
    /// Hears a link in the book being followed, and again when it's landed, after its relocation.
    /// `landed` says which.
    var onLink: ((_ landed: Bool) -> Void)?
    private var relocationListeners: [(ReaderLocation) -> Void] = []
    private var linkListeners: [(_ landed: Bool) -> Void] = []
    /// Counts relocations heard, so a reply can tell whether one came in while it was on its way.
    private var relocationsHeard = 0
    private(set) var currentLocation: ReaderLocation?
    /// The book that's open, its styles and its column limit, so a second view can be made to match.
    private(set) var bookURL: URL?
    private(set) var css = ""
    private(set) var columns = 2
    /// The width, in points, columns should have, or nil to let foliate pick. See `SpreadLayout`.
    private(set) var columnWidth: Double?
    var isBookOpen: Bool { isOpen }
    let webView: WKWebView
    /// Messages the page sent that weren't the bridge's. Nothing in a book should be able to send any.
    private(set) var rejectedMessageCount = 0

    /// Must outlast bridge.js's own 15 s limit on commands.
    static let commandTimeout: Duration = .seconds(20)
    private static let openTimeout: Duration = .seconds(60)
    private static let loadTimeout: Duration = .seconds(15)
    nonisolated static let defaultRemoteBlockRules = #"""
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """#
    private static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "BookWebView")

    private let scheme: BookScheme
    private let delegate = BookWebViewDelegate()
    private var isOpen = false
    private var isBlockingRemoteLoads = false
    /// Replaceable so tests can make the compile fail.
    var remoteBlockRules = BookWebView.defaultRemoteBlockRules
    /// Runs when a reply carrying a location has arrived, before the location is used. Tests use it
    /// to have a relocation overtake the reply, as one can when it's queued ahead of the reply's
    /// continuation.
    var replyArrived: (() async -> Void)?
    private var openGeneration = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    /// The navigation `pendingLoad` waits on, and the tag its `ready` message will carry. WebKit
    /// also reports on loads that have been replaced, which mustn't settle a newer one.
    private var pendingNavigation: WKNavigation?
    private var pendingLoadID: String?
    private var loadCount = 0
    private var relayoutTask: Task<Void, Never>?
    /// The call running bridge.js's `open`. Replacing the page can leave it unanswered.
    private var openReply: Reply?
    private var loadTimer: Task<Void, Never>?

    override init(frame: NSRect) {
        let webRoot = Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true)
        scheme = BookScheme(webRoot: webRoot)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: BookScheme.scheme)
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(delegate, name: "readme")
        webView = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: configuration)
        super.init(frame: frame)
        delegate.owner = self
        webView.navigationDelegate = delegate
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BookWebView is created in code")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed && isOpen { scheduleRelayout() }
    }

    /// Listeners hear a location before `onRelocate` does, so they're up to date by the time the
    /// window acts on it.
    func addRelocationListener(_ listener: @escaping (ReaderLocation) -> Void) {
        relocationListeners.append(listener)
    }

    /// Link listeners hear of a link before `onLink` does, as relocation listeners do.
    func addLinkListener(_ listener: @escaping (_ landed: Bool) -> Void) {
        linkListeners.append(listener)
    }

    // MARK: Opening

    func open(_ url: URL, at cfi: String?) async throws -> ReaderLocation {
        openGeneration += 1
        let generation = openGeneration
        openReply?.finish(.failure(BookWebViewError.superseded))
        openReply = nil
        isOpen = false
        currentLocation = nil
        bookURL = nil
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw BookWebViewError.unreadable
        }
        // The page can't paginate at no size. Later layout resizes it and foliate re-renders.
        if bounds.isEmpty { setFrameSize(NSSize(width: 1000, height: 700)) }
        let sizeAtOpen = bounds.size

        try await blockRemoteLoads()
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        try await loadReader()
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        let bookURL = scheme.serve(book: url)
        let location: ReaderLocation?
        do {
            location = try await call(
                "return await readmeBridge.open(url, cfi, css, columns, columnWidth)",
                arguments: [
                    "url": bookURL.absoluteString,
                    "cfi": cfi ?? NSNull(),
                    "css": css,
                    "columns": columns,
                    "columnWidth": columnWidth ?? NSNull(),
                ],
                as: ReaderLocation.self,
                timeout: Self.openTimeout,
                isOpenCall: true)
        } catch BookWebViewError.javaScript(let message) {
            // The page was replaced by a newer open, which is why this call failed.
            guard generation == openGeneration else { throw BookWebViewError.superseded }
            throw BookWebViewError.openFailed(message)
        }
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        guard let location else { throw BookWebViewError.openFailed("The book has no pages") }
        isOpen = true
        self.bookURL = url
        currentLocation = location
        if bounds.size != sizeAtOpen { scheduleRelayout() }
        return location
    }

    /// A required part of the design. WebKit won't run in a sandboxed app without the
    /// `network.client` entitlement, and the CSP allows remote images, styles and fonts, so this is
    /// what stops a book from calling out. Called before any page loads, and a failure makes `open`
    /// throw, so a book is never shown unprotected.
    private func blockRemoteLoads() async throws {
        guard !isBlockingRemoteLoads else { return }
        guard let store = WKContentRuleListStore.default() else {
            throw BookWebViewError.openFailed("Content rules are unavailable")
        }
        let compiled: WKContentRuleList?
        do {
            compiled = try await store.compileContentRuleList(
                forIdentifier: "readme-block-remote", encodedContentRuleList: remoteBlockRules)
        } catch {
            throw BookWebViewError.openFailed("Content rules did not compile: \(error)")
        }
        guard let compiled else { throw BookWebViewError.openFailed("Content rules did not compile") }
        // Overlapping opens can both get here.
        guard !isBlockingRemoteLoads else { return }
        webView.configuration.userContentController.add(compiled)
        isBlockingRemoteLoads = true
    }

    /// Returns when bridge.js says it's ready. WebKit's didFinish can come before modules have run.
    private func loadReader() async throws {
        finishLoad(.failure(BookWebViewError.superseded))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingLoad = continuation
            loadTimer = Task { [weak self] in
                try? await Task.sleep(for: Self.loadTimeout)
                if !Task.isCancelled { self?.finishLoad(.failure(BookWebViewError.timedOut)) }
            }
            loadCount += 1
            let id = String(loadCount)
            let url = BookScheme.readerURL(load: id)
            pendingLoadID = id
            pendingNavigation = webView.load(URLRequest(url: url))
        }
    }

    fileprivate func finishLoad(_ result: Result<Void, any Error>) {
        loadTimer?.cancel()
        loadTimer = nil
        pendingLoad?.resume(with: result)
        pendingLoad = nil
        pendingNavigation = nil
        pendingLoadID = nil
    }

    fileprivate func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard let navigation, navigation === pendingNavigation else { return }
        finishLoad(.failure(BookWebViewError.openFailed(error.localizedDescription)))
    }

    var isLoadingReader: Bool { pendingLoad != nil }

    /// Settles the current load if `load` is its tag. An earlier page's message is ignored.
    func readerIsReady(load: String?) {
        guard let load, load == pendingLoadID else { return }
        finishLoad(.success(()))
    }

    /// The main frame only changes while `open` is loading the reader, which rules out a reload from
    /// the context menu, as that would leave a blank page behind an open book. Not limited to the
    /// newest load: cancelling a replaced one here can stop the load that replaced it.
    fileprivate func allowsMainFrameNavigation(to url: URL) -> Bool {
        pendingLoad != nil && Self.allowsNavigation(to: url, inMainFrame: true)
    }

    // MARK: Moving

    func next() async -> ReaderLocation? {
        await navigate("return await readmeBridge.next()")
    }

    func previous() async -> ReaderLocation? {
        await navigate("return await readmeBridge.previous()")
    }

    func go(toCFI cfi: String) async -> ReaderLocation? {
        await navigate("return await readmeBridge.goToCFI(cfi)", arguments: ["cfi": cfi])
    }

    func go(toFraction fraction: Double) async -> ReaderLocation? {
        guard fraction.isFinite else { return nil }
        let clamped = min(1, max(0, fraction))
        return await navigate("return await readmeBridge.goToFraction(fraction)", arguments: ["fraction": clamped])
    }

    /// What following a link did.
    enum LinkResult: Equatable {
        /// It leads nowhere in the book.
        case unresolved
        /// It led somewhere, and this is where, or nil if the book was already there.
        case went(ReaderLocation?)
    }

    /// Goes to a place in the contents, by its href.
    func go(toHref href: String) async -> LinkResult {
        guard isOpen else { return .unresolved }
        let heard = relocationsHeard
        do {
            let reply = try await call(
                "return await readmeBridge.goToHref(href)", arguments: ["href": href], as: LinkReply.self)
            await replyArrived?()
            guard let reply, reply.resolved else { return .unresolved }
            take(reply.location, ifNothingHeardSince: heard)
            return .went(reply.location)
        } catch {
            Self.log.error("Following a link failed: \(String(describing: error), privacy: .public)")
            return .unresolved
        }
    }

    private struct LinkReply: Decodable, Sendable {
        var resolved: Bool
        var location: ReaderLocation?
    }

    /// The spread that holds the start of `page`, counted as `ReaderLocation.page` is.
    func go(toPage page: Int) async -> ReaderLocation? {
        await navigate("return await readmeBridge.goToPage(page)", arguments: ["page": page])
    }

    /// The first spread, which `isAtStart` is true on.
    func goToStart() async -> ReaderLocation? {
        await navigate("return await readmeBridge.goToStart()")
    }

    /// The last spread, which `isAtEnd` is true on. `go(toFraction: 1)` can stop a spread short of it.
    func goToEnd() async -> ReaderLocation? {
        await navigate("return await readmeBridge.goToEnd()")
    }

    private func navigate(_ body: String, arguments: [String: Any] = [:]) async -> ReaderLocation? {
        guard isOpen else { return nil }
        let heard = relocationsHeard
        do {
            let location = try await call(body, arguments: arguments, as: ReaderLocation.self)
            await replyArrived?()
            take(location, ifNothingHeardSince: heard)
            return location
        } catch {
            Self.log.error("Navigation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A relocation heard while a call ran is at least as new as the call's reply, which can be
    /// handled after it, so the reply's location only counts if none was. The call's own move is
    /// reported the same way, so nothing is lost.
    private func take(_ location: ReaderLocation?, ifNothingHeardSince heard: Int) {
        guard let location, relocationsHeard == heard else { return }
        currentLocation = location
    }

    /// Returns once the page has stopped changing, which a move doesn't wait for: any relayout has
    /// run, fonts and images are in, and foliate has paginated around them. Take snapshots after this.
    func settle() async {
        guard isOpen else { return }
        await relayoutTask?.value
        let heard = relocationsHeard
        do {
            let location = try await call("return await readmeBridge.settled()", as: ReaderLocation.self)
            await replyArrived?()
            take(location, ifNothingHeardSince: heard)
        } catch {
            Self.log.error("Settling failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Where the reader is, as the page holds it across layout changes: the place last gone to, or
    /// the start of where a turn landed. A book opened at a place it couldn't find has where it opened.
    func place() async -> String? {
        guard isOpen else { return nil }
        return try? await call("return readmeBridge.place()", as: String.self)
    }

    // MARK: Contents and styles

    func toc() async -> [TOCEntry] {
        guard isOpen else { return [] }
        do {
            return try await call("return await readmeBridge.toc()", as: [TOCEntry].self) ?? []
        } catch {
            Self.log.error("Reading the contents failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Applies reading styles and the number of columns, and holds the reader's place. They also
    /// apply to any book opened later. By the time this returns, the position has re-settled.
    ///
    /// `columns` is the most foliate will use. Accepted limit: foliate forces one column when the view
    /// is taller than wide, whatever is asked for here, and offers no way to override it.
    ///
    /// `columnWidth` is how wide each column should be, so that line width shows in the text. The page
    /// works out what to give foliate from its own size, and does so again when the view is resized.
    func applyStyles(css: String, columns: Int, columnWidth: Double? = nil) async {
        self.css = css
        self.columns = max(1, columns)
        self.columnWidth = columnWidth
        guard isOpen else { return }
        let heard = relocationsHeard
        do {
            _ = try await call(
                "await readmeBridge.applyStyles(css, columns, columnWidth)",
                arguments: ["css": css, "columns": self.columns, "columnWidth": columnWidth ?? NSNull()],
                as: Bool.self)
            let location = try await call(
                "return readmeBridge.location()", as: ReaderLocation.self)
            await replyArrived?()
            take(location, ifNothingHeardSince: heard)
        } catch {
            Self.log.error("Applying styles failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// foliate caps columns by the width it's given, and in a hidden window nothing else tells
    /// the page it was resized, so the bridge lays out again and holds the reader's place.
    private func scheduleRelayout() {
        relayoutTask?.cancel()
        relayoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, self.isOpen else { return }
            _ = try? await self.call(
                "readmeBridge.resized(width)",
                arguments: ["width": Double(self.bounds.width)],
                as: Bool.self)
        }
    }

    // MARK: JavaScript

    /// Runs `body` as an async function and decodes what it returns. A hung call throws
    /// `.timedOut` rather than waiting forever.
    ///
    /// The value travels inside a JSON string: WebKit's Swift overlay traps if a call answers with
    /// neither a result nor an error, which it can do when JavaScript returns `undefined`.
    func call<Value: Decodable & Sendable>(
        _ body: String,
        arguments: [String: Any] = [:],
        as type: Value.Type,
        timeout: Duration = BookWebView.commandTimeout,
        isOpenCall: Bool = false
    ) async throws -> Value? {
        let wrapped = "return JSON.stringify({ value: (await (async () => { \(body) })()) ?? null })"
        let json = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let reply = Reply(continuation)
            if isOpenCall { openReply = reply }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { reply.finish(.failure(BookWebViewError.timedOut)) }
            }
            webView.callAsyncJavaScript(wrapped, arguments: arguments, in: nil, in: .page) { result in
                timer.cancel()
                switch result {
                case .success(let value):
                    reply.finish(.success(value as? String ?? "{}"))
                case .failure(let error):
                    reply.finish(.failure(BookWebViewError.javaScript(Self.message(of: error))))
                }
            }
        }
        do {
            return try JSONDecoder().decode(Reply.Envelope<Value>.self, from: Data(json.utf8)).value
        } catch {
            throw BookWebViewError.javaScript("Unexpected reply: \(error)")
        }
    }

    private static func message(of error: any Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    // MARK: Events from the page

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == BookScheme.scheme,
              let text = message.body as? String,
              let event = try? JSONDecoder().decode(BridgeEvent.self, from: Data(text.utf8))
        else {
            rejectedMessageCount += 1
            return
        }
        switch (event.type, event.location) {
        case ("ready", _):
            readerIsReady(load: event.load)
        case ("link", nil):
            let landed = event.landed ?? true
            linkListeners.forEach { $0(landed) }
            onLink?(landed)
        case ("relocate", let location?):
            relocationsHeard += 1
            currentLocation = location
            relocationListeners.forEach { $0(location) }
            onRelocate?(location)
        default:
            rejectedMessageCount += 1
        }
    }

    fileprivate func webContentProcessDied() {
        Self.log.error("The web content process stopped")
        isOpen = false
        finishLoad(.failure(BookWebViewError.openFailed("The web content process stopped")))
    }

    /// Only the reader page may fill the main frame, and a book's frames can't leave the app.
    nonisolated static func allowsNavigation(to url: URL, inMainFrame: Bool) -> Bool {
        if inMainFrame { return BookScheme.isReader(url) }
        return ["blob", "about"].contains(url.scheme?.lowercased())
    }

    private struct BridgeEvent: Decodable {
        var type: String
        var location: ReaderLocation?
        var load: String?
        var landed: Bool?
    }
}

/// Finishes a waiting call once, whichever of the reply and the timeout comes first.
@MainActor
private final class Reply {
    struct Envelope<Value: Decodable>: Decodable {
        var value: Value?
    }

    private var continuation: CheckedContinuation<String, any Error>?

    init(_ continuation: CheckedContinuation<String, any Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<String, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// WebKit keeps its message handlers strongly, so this sits between it and `BookWebView`.
@MainActor
private final class BookWebViewDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var owner: BookWebView?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, let frame = action.targetFrame else {
            decisionHandler(.cancel)
            return
        }
        let allowed = frame.isMainFrame
            ? owner?.allowsMainFrameNavigation(to: url) ?? false
            : BookWebView.allowsNavigation(to: url, inMainFrame: false)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        owner?.navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        owner?.navigationFailed(navigation, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.webContentProcessDied()
    }
}
