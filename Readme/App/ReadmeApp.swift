import AppKit
import SwiftUI

/// Anchor class so tests can locate the app bundle via `Bundle(for:)`.
final class BundleToken {}

@main
struct ReadmeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open…") { appDelegate.chooseBook() }
                        .keyboardShortcut("o")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var trial: TrialReaderWindow?

    /// Tests are hosted in the app, and shouldn't have a reader window in their way.
    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isTesting { showTrial() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        showTrial().open(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showTrial()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isTesting
    }

    func chooseBook() {
        showTrial().chooseBook()
    }

    @discardableResult
    private func showTrial() -> TrialReaderWindow {
        let window = trial ?? TrialReaderWindow()
        trial = window
        window.show()
        return window
    }
}
