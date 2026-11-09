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
                    item(.toggleHighlights)
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

    private func item(_ command: ReaderCommand) -> some View {
        CommandItem(command: command, state: appDelegate.state) { appDelegate.perform(command) }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// A reader command in the menus. The reading window's own key monitor sees these keys first. The
/// menu is for finding them, and for clicking. Over the library, only what's about the window is
/// available.
private struct CommandItem: View {
    let command: ReaderCommand
    @ObservedObject var state: AppState
    let action: () -> Void

    var body: some View {
        Button(command.title, action: action)
            .keyboardShortcut(
                KeyEquivalent(Character(command.shortcut.key)),
                modifiers: ReadmeApp.modifiers(command.shortcut.modifiers))
            .disabled(state.isShowingLibrary && command != .showLibrary && command != .toggleFullscreen)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var app: AppCoordinator?
    let state = AppState()

    /// Tests are hosted in the app, and shouldn't have a window in their way.
    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The View menu has the reader's own fullscreen item, with plain F beside ⌃⌘F.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isTesting { coordinator().launch() }
    }

    /// Books dropped on the Dock icon, or opened from the Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isTesting, !urls.isEmpty else { return }
        coordinator().open(urls)
    }

    private static let quitPatience: Duration = .seconds(2)

    /// The reader's place and the library are saved as they read, and this waits for the last of
    /// them to be written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app else { return .terminateNow }
        // A stuck page mustn't stop the app quitting.
        Deadline.wait(for: { await app.prepareToQuit() }, atMost: Self.quitPatience) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Clicking the Dock icon brings the window back, showing what it showed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !isTesting else { return true }
        coordinator().showWindow()
        return true
    }

    /// Closing the window leaves the app running, as a Mac app does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func chooseBook() {
        guard !isTesting else { return }
        coordinator().chooseBook()
    }

    func perform(_ command: ReaderCommand) {
        app?.reader.perform(command)
    }

    private func coordinator() -> AppCoordinator {
        if let app { return app }
        let made = AppCoordinator.standard(state: state)
        app = made
        return made
    }
}
