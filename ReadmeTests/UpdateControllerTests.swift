import Foundation
import Testing
@testable import Readme

/// What GitHub says, what the reader clicks, and what the controller showed and installed.
@MainActor
private final class Scene {
    var latest = "v1.1"
    var online = true
    var clicks: [Int?] = []
    private(set) var shown: [UpdatePrompt] = []
    private(set) var installed: [Release] = []
    private(set) var asked = 0

    func click(_ prompt: UpdatePrompt) -> Int? {
        shown.append(prompt)
        return clicks.isEmpty ? nil : clicks.removeFirst()
    }

    func install(_ release: Release) { installed.append(release) }
}

private struct Offline: Error {}

@MainActor
@Suite struct UpdateControllerTests {
    let defaults: UserDefaults
    let suite: String
    private let scene = Scene()
    let now = Date(timeIntervalSince1970: 1_000_000)

    init() {
        suite = "com.rajanchavda.Readme.tests.updateflow.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    private func clean() { defaults.removePersistentDomain(forName: suite) }

    private func controller() -> UpdateController {
        let scene = scene
        let box = LatestBox(scene: scene)
        let checker = UpdateChecker(current: AppVersion("1.1")!, defaults: defaults) { _ in try await box.answer() }
        return UpdateController(
            checker: checker,
            show: { prompt, _ in scene.click(prompt) },
            install: { scene.install($0) },
            now: { [now] in now })
    }

    private static let page = URL(string: "https://github.com/rajanchavda/readme/releases/tag/v1.2")!
    private var newer: Release { Release(version: AppVersion("1.2")!, page: Self.page) }

    // MARK: Asking

    @Test func askingShowsANewerVersionAndUpdateInstallsIt() async {
        defer { clean() }
        scene.latest = "v1.2"
        scene.clicks = [0]
        await controller().checkNow()
        #expect(scene.shown == [.newer(newer, current: AppVersion("1.1")!)])
        #expect(scene.installed == [newer])
    }

    @Test func notNowRemembersTheVersion() async {
        defer { clean() }
        scene.latest = "v1.2"
        scene.clicks = [1]
        let updates = controller()
        await updates.checkNow()
        #expect(scene.installed.isEmpty)
        #expect(!updates.checker.shouldShow(newer, automatically: true))
    }

    @Test func askingSaysWhenItsUpToDate() async {
        defer { clean() }
        await controller().checkNow()
        #expect(scene.shown == [.upToDate(AppVersion("1.1")!)])
    }

    @Test func askingSaysWhenGitHubCantBeReached() async {
        defer { clean() }
        scene.online = false
        await controller().checkNow()
        #expect(scene.shown == [.failed])
    }

    // MARK: On its own

    @Test func automaticChecksStayQuietUnlessThereIsSomethingNew() async {
        defer { clean() }
        let updates = controller()
        updates.checker.automatic = true
        await updates.checkIfDue()
        scene.online = false
        await updates.checkIfDue()
        #expect(scene.shown.isEmpty)
    }

    @Test func automaticChecksShowANewVersionOnce() async {
        defer { clean() }
        scene.latest = "v1.2"
        scene.clicks = [1]
        let updates = controller()
        updates.checker.automatic = true
        await updates.checkIfDue()
        #expect(scene.shown.count == 1)
        defaults.removeObject(forKey: "updates.lastChecked")
        await updates.checkIfDue()
        #expect(scene.shown.count == 1)
    }

    @Test func nothingIsCheckedUntilTheReaderSaysSo() async {
        defer { clean() }
        await controller().checkIfDue()
        #expect(scene.shown.isEmpty)
    }

    // MARK: The question

    @Test func theFirstLaunchAsksNothing() async {
        defer { clean() }
        await controller().launched()
        #expect(scene.shown.isEmpty)
    }

    @Test func theSecondLaunchAsksAndYesChecksRightAway() async {
        defer { clean() }
        scene.latest = "v1.2"
        scene.clicks = [0, 1]
        await controller().launched()
        let updates = controller()
        await updates.launched()
        #expect(scene.shown == [.askAutomatic, .newer(newer, current: AppVersion("1.1")!)])
        #expect(updates.checker.automatic == true)
    }

    @Test func noMeansNoChecks() async {
        defer { clean() }
        scene.latest = "v1.2"
        scene.clicks = [1]
        await controller().launched()
        let updates = controller()
        await updates.launched()
        #expect(scene.shown == [.askAutomatic])
        #expect(updates.checker.automatic == false)
        await updates.launched()
        #expect(scene.shown == [.askAutomatic])
    }

    /// If the question couldn't be shown (a sheet was up), it's asked another time.
    @Test func anUnshownQuestionIsAskedLater() async {
        defer { clean() }
        await controller().launched()
        let updates = controller()
        await updates.launched()
        #expect(updates.checker.automatic == nil)
        #expect(updates.checker.shouldAskAboutAutomatic)
    }

    // MARK: Words

    @Test func theNewVersionAlert() {
        let prompt = UpdatePrompt.newer(newer, current: AppVersion("1.1")!)
        #expect(prompt.message == "Readme 1.2 is available")
        #expect(prompt.informative == """
            You have 1.1. Readme will quit, install the update and open again. Your place and \
            notes are saved first.
            """)
        #expect(prompt.buttons == ["Update and Restart", "Not Now"])
    }

    @Test func theOtherAlerts() {
        #expect(UpdatePrompt.upToDate(AppVersion("1.1")!).message == "Readme is up to date")
        #expect(UpdatePrompt.upToDate(AppVersion("1.1")!).informative == "You have the latest version, 1.1.")
        #expect(UpdatePrompt.failed.message == "Couldn't check for updates")
        #expect(UpdatePrompt.askAutomatic.message == "Check for updates automatically?")
        #expect(UpdatePrompt.askAutomatic.buttons == ["Check Automatically", "Don't Check"])
    }
}

/// Lets the fake fetch, which runs off the main actor, read the scene.
private final class LatestBox: Sendable {
    let scene: Scene
    init(scene: Scene) { self.scene = scene }

    func answer() async throws -> Data {
        let (online, latest) = await MainActor.run { (scene.online, scene.latest) }
        guard online else { throw Offline() }
        return Data("""
        {"tag_name": "\(latest)", "html_url": "https://github.com/rajanchavda/readme/releases/tag/\(latest)",
         "draft": false, "prerelease": false}
        """.utf8)
    }
}
