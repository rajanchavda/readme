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
@MainActor
final class BookWebView: NSView {
    var onRelocate: ((ReaderLocation) -> Void)?
    private(set) var currentLocation: ReaderLocation?
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
    private var openGeneration = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var loadTimer: Task<Void, Never>?
    private var css = ""
    private var columns = 2

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

    // MARK: Opening

    func open(_ url: URL, at cfi: String?) async throws -> ReaderLocation {
        openGeneration += 1
        let generation = openGeneration
        isOpen = false
        currentLocation = nil
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw BookWebViewError.unreadable
        }
        // The page can't paginate at no size. Later layout resizes it and foliate re-renders.
        if bounds.isEmpty { setFrameSize(NSSize(width: 1000, height: 700)) }

        try await blockRemoteLoads()
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        try await loadReader()
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        let bookURL = scheme.serve(book: url)
        let location: ReaderLocation?
        do {
            location = try await call(
                "return await readmeBridge.open(url, cfi, css, columns)",
                arguments: [
                    "url": bookURL.absoluteString,
                    "cfi": cfi ?? NSNull(),
                    "css": css,
                    "columns": columns,
                ],
                as: ReaderLocation.self,
                timeout: Self.openTimeout)
        } catch BookWebViewError.javaScript(let message) {
            throw BookWebViewError.openFailed(message)
        }
        guard generation == openGeneration else { throw BookWebViewError.superseded }
        guard let location else { throw BookWebViewError.openFailed("The book has no pages") }
        isOpen = true
        currentLocation = location
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
            webView.load(URLRequest(url: BookScheme.readerURL))
        }
    }

    fileprivate func finishLoad(_ result: Result<Void, any Error>) {
        loadTimer?.cancel()
        loadTimer = nil
        pendingLoad?.resume(with: result)
        pendingLoad = nil
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

    private func navigate(_ body: String, arguments: [String: Any] = [:]) async -> ReaderLocation? {
        guard isOpen else { return nil }
        do {
            let location = try await call(body, arguments: arguments, as: ReaderLocation.self)
            if let location { currentLocation = location }
            return location
        } catch {
            Self.log.error("Navigation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
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
    func applyStyles(css: String, columns: Int) async {
        self.css = css
        self.columns = max(1, columns)
        guard isOpen else { return }
        do {
            _ = try await call(
                "await readmeBridge.applyStyles(css, columns)",
                arguments: ["css": css, "columns": self.columns],
                as: Bool.self)
            let location = try await call(
                "return readmeBridge.location()", as: ReaderLocation.self)
            if let location { currentLocation = location }
        } catch {
            Self.log.error("Applying styles failed: \(String(describing: error), privacy: .public)")
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
        timeout: Duration = BookWebView.commandTimeout
    ) async throws -> Value? {
        let wrapped = "return JSON.stringify({ value: (await (async () => { \(body) })()) ?? null })"
        let json = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            let reply = Reply(continuation)
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
            finishLoad(.success(()))
        case ("relocate", let location?):
            currentLocation = location
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
        if inMainFrame { return url == BookScheme.readerURL }
        return ["blob", "about", BookScheme.scheme].contains(url.scheme?.lowercased())
    }

    private struct BridgeEvent: Decodable {
        var type: String
        var location: ReaderLocation?
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
        let allowed = action.request.url.map {
            BookWebView.allowsNavigation(to: $0, inMainFrame: action.targetFrame?.isMainFrame ?? true)
        } ?? false
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        owner?.finishLoad(.failure(BookWebViewError.openFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        owner?.finishLoad(.failure(BookWebViewError.openFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        owner?.webContentProcessDied()
    }
}
