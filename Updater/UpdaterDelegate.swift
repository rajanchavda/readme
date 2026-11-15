import AppKit

/// Readme Updater: downloads and checks the latest release while Readme stays open, then asks to
/// restart it. Restart Now quits Readme, puts the update in place and opens it again. Later keeps
/// the update ready and installs it the next time Readme quits, without opening it again. On any
/// failure the old Readme is left as it was, after saying why.
@MainActor
final class UpdaterDelegate: NSObject, NSApplicationDelegate {
    private enum Phase {
        case downloading
        /// Downloaded and checked, waiting for the reader to restart or quit Readme.
        case ready(PreparedUpdate)
        case restarting(PreparedUpdate)
        case installing
        /// Done, or given up, and quitting.
        case finished

        var isDownloading: Bool {
            if case .downloading = self { true } else { false }
        }
    }

    private var phase = Phase.downloading
    private var window: NSWindow?
    private let status = NSTextField(labelWithString: "Downloading the update…")
    private let bar = NSProgressIndicator()
    private let buttons = NSStackView()
    private var preparing: Task<Void, Never>?
    /// Keeps App Nap off. Hidden after Later, with no window, the updater would otherwise be
    /// slowed until it no longer noticed Readme quit, and its download slowed too.
    private var activity: NSObjectProtocol?
    private var installing: Task<Void, Never>?

    /// The Readme.app this updater sits in: Readme.app/Contents/Helpers/Readme Updater.app.
    private let app = Bundle.main.bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private lazy var installer = UpdateInstaller(
        app: app, world: .live,
        scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ReadmeUpdate-\(UUID().uuidString)"))

    private static let quitPatience: Duration = .seconds(30)
    private static let releases = URL(string: "https://github.com/rajanchavda/readme/releases/latest")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Downloading and installing a Readme update")
        makeWindow()
        let byHomebrew = Homebrew.apps.contains { $0.standardizedFileURL == app.standardizedFileURL }
            && Homebrew.find() != nil
        showDownloading(byHomebrew ? "Downloading the update with Homebrew…" : "Downloading the update…")
        preparing = Task { await prepare() }
    }

    /// Readme starts the updater again when the reader checks for updates while one is under way.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        reveal()
        return false
    }

    /// Logging out mustn't stop an install halfway, or leave a disk image mounted.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch phase {
        case .finished:
            return .terminateNow
        case .installing:
            guard let installing else { return .terminateNow }
            Task { await installing.value; sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        case let .ready(prepared), let .restarting(prepared):
            Task { await installer.discard(prepared); sender.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        case .downloading:
            preparing?.cancel()
            return .terminateNow
        }
    }

    // MARK: Steps

    private func prepare() async {
        let installer = installer
        let bar = bar
        do {
            let prepared = try await installer.prepare { fraction in
                Task { @MainActor in
                    bar.isIndeterminate = false
                    bar.doubleValue = fraction
                }
            }
            if Task.isCancelled { return await installer.discard(prepared) }
            if isReadmeRunning {
                phase = .ready(prepared)
                showReady(prepared.version)
                watchForReadmeToQuit()
            } else {
                // Readme was quit while this downloaded. It's put in place, and not opened again.
                install(prepared, reopen: false)
            }
        } catch is CancellationError {
            NSApp.terminate(nil)
        } catch InstallError.upToDate {
            NSApp.terminate(nil)
        } catch {
            if Task.isCancelled { return NSApp.terminate(nil) }
            fail(Self.message(error), reopen: false)
        }
    }

    @objc private func cancel() {
        preparing?.cancel()
        NSApp.terminate(nil)
    }

    @objc private func later() {
        guard case .ready = phase else { return }
        window?.orderOut(nil)
        NSApp.hide(nil)
    }

    @objc private func restartNow() {
        guard case let .ready(prepared) = phase else { return }
        phase = .restarting(prepared)
        showDownloading("Quitting Readme…")
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        Task {
            for readme in runningReadmes { readme.terminate() }
            if await waitForReadmeToQuit() {
                install(prepared, reopen: true)
            } else {
                phase = .ready(prepared)
                showReady(prepared.version, note: "Readme didn't quit. Quit it, or try again.")
                watchForReadmeToQuit()
            }
        }
    }

    /// Readme quitting while an update waits is the moment to put it in place. It's looked for
    /// rather than waited on: just after the system says an app quit, it may still be listed.
    private func watchForReadmeToQuit() {
        Task {
            while case let .ready(prepared) = phase {
                if !isReadmeRunning { return install(prepared, reopen: false) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func install(_ prepared: PreparedUpdate, reopen: Bool) {
        phase = .installing
        // Also when installing quietly after Readme quit, so the window says so if it's brought back.
        showInstalling("Installing Readme \(prepared.version)…", reveal: reopen)
        let installer = installer
        installing = Task {
            do {
                _ = try await installer.finish(prepared)
                done(reopen: reopen)
            } catch InstallError.upToDate {
                done(reopen: reopen)
            } catch {
                fail(Self.message(error), reopen: reopen)
            }
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? InstallError)?.message ?? error.localizedDescription
    }

    // MARK: Readme

    private var runningReadmes: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleInfo.readme)
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
    }

    private var isReadmeRunning: Bool { !runningReadmes.isEmpty }

    private func waitForReadmeToQuit() async -> Bool {
        let deadline = ContinuousClock.now + Self.quitPatience
        while ContinuousClock.now < deadline {
            if !isReadmeRunning { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Opens Readme, if asked to, then quits. The phase moves on first: quitting otherwise waits for
    /// the install to finish, and this may be called from the install itself.
    private func done(reopen: Bool) {
        phase = .finished
        guard reopen else { return NSApp.terminate(nil) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// Says what went wrong, then opens Readme (the old one) if it was quit for the update, and quits.
    private func fail(_ message: String, reopen: Bool) {
        phase = .finished
        window?.orderOut(nil)
        NSApp.unhide(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Readme couldn't be updated"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Release Page")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(Self.releases) }
        done(reopen: reopen)
    }

    // MARK: Window

    private func reveal() {
        NSApp.unhide(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func showDownloading(_ text: String) {
        status.stringValue = text
        bar.isHidden = false
        setButtons(phase.isDownloading ? [button("Cancel", #selector(cancel), escape: true)] : [])
        reveal()
    }

    private func showInstalling(_ text: String, reveal shouldReveal: Bool) {
        status.stringValue = text
        bar.isHidden = false
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        setButtons([])
        if shouldReveal { reveal() }
    }

    private func showReady(_ version: AppVersion, note: String? = nil) {
        status.stringValue = note ?? "Readme \(version) is ready. Restart Readme to finish installing it."
        bar.isHidden = true
        let restart = button("Restart Now", #selector(restartNow))
        restart.keyEquivalent = "\r"
        setButtons([button("Later", #selector(later), escape: true), restart])
        reveal()
    }

    private func button(_ title: String, _ action: Selector, escape: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if escape { button.keyEquivalent = "\u{1b}" }
        return button
    }

    private func setButtons(_ list: [NSButton]) {
        for view in buttons.arrangedSubviews { buttons.removeArrangedSubview(view); view.removeFromSuperview() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.addArrangedSubview(spacer)
        for button in list { buttons.addArrangedSubview(button) }
        buttons.isHidden = list.isEmpty
    }

    private func makeWindow() {
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 0
        status.preferredMaxLayoutWidth = 320
        bar.style = .bar
        bar.isIndeterminate = true
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let column = NSStackView(views: [status, bar, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [bar, buttons] { view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40).isActive = true }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.title = "Updating Readme"
        window.contentView = column
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}

extension InstallWorld {
    /// The real network and tools. Nothing is cached or remembered between runs.
    static let live = InstallWorld(
        fetch: { url in
            let (data, response) = try await session.data(for: request(url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        },
        download: { url, destination, progress in
            try await download(url, to: destination, progress: progress)
        },
        run: { tool, arguments in
            try await Task.detached { try runTool(tool, arguments) }.value
        })

    /// No waiting for connectivity: a dropped connection would then sit quietly for as long as the
    /// resource timeout allows. A request with nothing for a minute fails, and `download` resumes it.
    private static let session = URLSession(configuration: .ephemeral)

    /// Readme stays open while the update downloads, so the Mac may sleep or lose its network
    /// meanwhile. With pauses of up to half a minute, this keeps trying for about ten minutes.
    private static let retries = 20

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
    }

    /// Downloads, carrying on from where it stopped when the connection drops, as when the Mac
    /// sleeps, and trying a few times, further apart each time, before giving up.
    private static func download(
        _ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var resumeData: Data?
        var attempt = 0
        while true {
            do {
                return try await downloadOnce(url, to: destination, resumingFrom: resumeData, progress: progress)
            } catch let error as URLError
                        where attempt < retries && (isPassing(error) || resumeData != nil) && !Task.isCancelled {
                // A resume that fails for any other reason starts again from the beginning.
                resumeData = isPassing(error) ? error.downloadTaskResumeData : nil
                attempt += 1
                try await Task.sleep(for: .seconds(min(5 * attempt, 30)))
            }
        }
    }

    /// Errors from a connection that dropped or wasn't there, which may well work a little later.
    private static func isPassing(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
         .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .secureConnectionFailed].contains(error.code)
    }

    /// One download task, watched through its progress, and cancelled with the task awaiting it.
    private static func downloadOnce(
        _ url: URL, to destination: URL, resumingFrom resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let box = DownloadBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let finished: @Sendable (URL?, URLResponse?, Error?) -> Void = { file, response, error in
                    box.finish()
                    // The file is removed once this returns, so it's moved here.
                    do {
                        if let error { throw error }
                        // A resumed download answers 206, for the part it carries on with.
                        guard let file, [200, 206].contains((response as? HTTPURLResponse)?.statusCode) else {
                            throw URLError(.badServerResponse)
                        }
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: file, to: destination)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let task = resumeData.map { session.downloadTask(withResumeData: $0, completionHandler: finished) }
                    ?? session.downloadTask(with: request(url), completionHandler: finished)
                box.start(task) { progress($0) }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func runTool(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a tool that fills the pipe would otherwise never finish.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// Holds a download task and the watch on its progress, so either side can reach them safely.
private final class DownloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var watch: NSKeyValueObservation?
    private var isCancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (Double) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        watch = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
        task.resume()
        if isCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        task?.cancel()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        watch?.invalidate()
        watch = nil
    }
}
