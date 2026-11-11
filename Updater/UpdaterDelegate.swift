import AppKit

/// Readme Updater: waits for Readme to quit, installs the latest release over it, and opens it
/// again. On any failure the old Readme is left as it was and opened again, after saying why.
@MainActor
final class UpdaterDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let status = NSTextField(labelWithString: "Waiting for Readme to quit…")

    /// The Readme.app this updater sits in: Readme.app/Contents/Helpers/Readme Updater.app.
    private let app = Bundle.main.bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let quitPatience: Duration = .seconds(30)

    func applicationDidFinishLaunching(_ notification: Notification) {
        showWindow()
        Task { await update() }
    }

    private func update() async {
        guard await waitForReadmeToQuit() else {
            return finish(failure: "Readme didn't quit, so it couldn't be replaced. Quit it and try again.", page: nil)
        }
        let byHomebrew = Homebrew.apps.contains { $0.standardizedFileURL == app.standardizedFileURL }
            && Homebrew.find() != nil
        status.stringValue = byHomebrew ? "Updating with Homebrew…" : "Downloading the update…"
        let installer = UpdateInstaller(
            app: app, world: .live,
            scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ReadmeUpdate-\(UUID().uuidString)"))
        do {
            let version = try await installer.install()
            status.stringValue = "Installed Readme \(version). Opening it…"
            finish(failure: nil, page: nil)
        } catch InstallError.upToDate {
            finish(failure: nil, page: nil)
        } catch let error as InstallError {
            finish(failure: error.message, page: Self.releases)
        } catch {
            finish(failure: error.localizedDescription, page: Self.releases)
        }
    }

    private static let releases = URL(string: "https://github.com/rajanchavda/readme/releases/latest")!

    private func waitForReadmeToQuit() async -> Bool {
        let deadline = ContinuousClock.now + Self.quitPatience
        while ContinuousClock.now < deadline {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppBundleInfo.readme)
                .contains { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
            if !running { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// Says what went wrong, if anything, then opens Readme (new or old) and quits.
    private func finish(failure: String?, page: URL?) {
        if let failure {
            window?.orderOut(nil)
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Readme couldn't be updated"
            alert.informativeText = failure
            alert.addButton(withTitle: "OK")
            if page != nil { alert.addButton(withTitle: "Open Release Page") }
            if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func showWindow() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let row = NSStackView(views: [spinner, status])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 64), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.title = "Updating Readme"
        window.contentView = row
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        download: { url, destination in
            let (file, response) = try await session.download(for: request(url))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
        },
        run: { tool, arguments in
            try await Task.detached { try runTool(tool, arguments) }.value
        })

    private static let session = URLSession(configuration: .ephemeral)

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        return request
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
