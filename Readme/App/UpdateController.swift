import AppKit

/// An alert the update checker puts up, and its words.
enum UpdatePrompt: Equatable {
    case newer(Release, current: AppVersion)
    case upToDate(AppVersion)
    case failed
    case askAutomatic

    var message: String {
        switch self {
        case let .newer(release, _): "Readme \(release.version) is available"
        case .upToDate: "Readme is up to date"
        case .failed: "Couldn't check for updates"
        case .askAutomatic: "Check for updates automatically?"
        }
    }

    var informative: String {
        switch self {
        case let .newer(_, current):
            """
            You have \(current). Download the new version and drag it into Applications, choosing Replace.

            Installed with Homebrew? Run brew upgrade --cask readme instead.
            """
        case let .upToDate(current): "You have the latest version, \(current)."
        case .failed: "GitHub couldn't be reached. Check your internet connection and try again."
        case .askAutomatic:
            """
            Readme can check GitHub once a day and tell you when a new version is out. Nothing about \
            you or your books is sent. You can change this later in the Readme menu.
            """
        }
    }

    var buttons: [String] {
        switch self {
        case .newer: ["Download", "Not Now"]
        case .upToDate, .failed: ["OK"]
        case .askAutomatic: ["Check Automatically", "Don't Check"]
        }
    }
}

/// When to check for updates and what to tell the reader. A check the reader asks for always
/// answers. One made on its own speaks only when there's a new version they haven't turned down.
@MainActor
final class UpdateController {
    /// Puts up a prompt and gives the index of the button clicked, or nil if it couldn't be shown.
    /// The flag says the reader asked, so it should be shown even with no window to attach it to.
    typealias Show = @MainActor (UpdatePrompt, _ asked: Bool) async -> Int?

    let checker: UpdateChecker
    private let show: Show
    private let open: @MainActor (URL) -> Void
    private let now: () -> Date
    private var isChecking = false

    init(checker: UpdateChecker, show: @escaping Show,
         open: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.show = show
        self.open = open
        self.now = now
    }

    /// Once per launch: from the second launch on, asks whether to check automatically until the
    /// reader has answered, then checks if a check is due.
    func launched() async {
        checker.noteLaunch()
        if checker.shouldAskAboutAutomatic {
            switch await show(.askAutomatic, false) {
            case 0: checker.automatic = true
            case 1: checker.automatic = false
            default: break
            }
        }
        await checkIfDue()
    }

    /// Check for Updates… in the Readme menu.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        switch await checker.check(now: now()) {
        case let .newer(release): await offer(release, asked: true)
        case .upToDate: _ = await show(.upToDate(checker.current), true)
        case .failed: _ = await show(.failed, true)
        }
    }

    func checkIfDue() async {
        guard !isChecking, checker.isDue(now: now()) else { return }
        isChecking = true
        defer { isChecking = false }
        guard case let .newer(release) = await checker.check(now: now()),
              checker.shouldShow(release, automatically: true) else { return }
        await offer(release, asked: false)
    }

    private func offer(_ release: Release, asked: Bool) async {
        switch await show(.newer(release, current: checker.current), asked) {
        case 0: open(release.page)
        case 1: checker.decline(release)
        default: break
        }
    }

    /// Runs for as long as the app does: the launch's turn a little after launch, so the window is
    /// up first, then a look every hour in case a day has passed with the app left open.
    func run() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.launched()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                await self.checkIfDue()
            }
        }
    }

    /// Shows a prompt as a sheet on the window if it's up and free, or on its own if the reader
    /// asked. A check made on its own doesn't interrupt another sheet or bring the app forward.
    static func present(on window: NSWindow?) -> Show {
        { [weak window] prompt, asked in
            let alert = NSAlert()
            alert.messageText = prompt.message
            alert.informativeText = prompt.informative
            for title in prompt.buttons { alert.addButton(withTitle: title) }
            if prompt.buttons.count > 1 { alert.buttons.last?.keyEquivalent = "\u{1b}" }
            let response: NSApplication.ModalResponse
            if let window, window.isVisible, window.attachedSheet == nil {
                response = await alert.beginSheetModal(for: window)
            } else if asked {
                NSApp.activate()
                response = alert.runModal()
            } else {
                return nil
            }
            return response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        }
    }
}
