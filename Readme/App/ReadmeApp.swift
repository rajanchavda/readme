import AppKit
import SwiftUI

/// Waits for work to finish, or for a time, whichever comes first, then goes on once.
enum Deadline {
    @MainActor
    static func wait(
        for work: @escaping @MainActor () async -> Void, atMost bound: Duration,
        then: @escaping @MainActor () -> Void
    ) {
        let once = Once(then)
        Task { @MainActor in
            await work()
            once.run()
        }
        Task { @MainActor in
            try? await Task.sleep(for: bound)
            once.run()
        }
    }

    @MainActor
    private final class Once {
        private var action: (@MainActor () -> Void)?

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func run() {
            let action = self.action
            self.action = nil
            action?()
        }
    }
}

/// Anchor class so tests can locate the app bundle via `Bundle(for:)`.
final class BundleToken {}

@main
struct ReadmeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        BundledFonts.register()
    }

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Open…") { appDelegate.chooseBook() }
                        .keyboardShortcut("o")
                }
                CommandGroup(after: .toolbar) {
                    item(.biggerText)
                    item(.smallerText)
                    Divider()
                    item(.toggleTOC)
                    item(.showLibrary)
                    Divider()
                    item(.toggleFullscreen)
                }
                CommandMenu("Go") {
                    item(.goToStart)
                    item(.goToEnd)
                    item(.goToPage)
                }
            }
    }

    /// The reading window's own key monitor sees these keys first. The menu is for finding them, and
    /// for clicking.
    private func item(_ command: ReaderCommand) -> some View {
        Button(command.title) { appDelegate.perform(command) }
            .keyboardShortcut(
                KeyEquivalent(Character(command.shortcut.key)), modifiers: Self.modifiers(command.shortcut.modifiers))
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var reader: ReaderWindowController?

    /// Tests are hosted in the app, and shouldn't have a reader window in their way.
    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The View menu has the reader's own fullscreen item, with plain F beside ⌃⌘F.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isTesting { showReader() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let reader = showReader()
        Task { await reader.open(url) }
    }

    private static let quitPatience: Duration = .seconds(2)

    /// The reader's place is saved as they read, and this waits for the last of it to be written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reader else { return .terminateNow }
        // A stuck page mustn't stop the app quitting.
        Deadline.wait(for: { await reader.keepPlace() }, atMost: Self.quitPatience) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showReader()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !isTesting
    }

    func chooseBook() {
        showReader().chooseBook()
    }

    func perform(_ command: ReaderCommand) {
        reader?.perform(command)
    }

    /// Until the library arrives, launching shows the reading window, which asks for a book.
    @discardableResult
    private func showReader() -> ReaderWindowController {
        let window = reader ?? ReaderWindowController(positions: isTesting ? nil : .standard)
        reader = window
        window.show()
        return window
    }
}
