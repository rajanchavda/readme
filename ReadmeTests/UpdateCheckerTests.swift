import Foundation
import Testing
@testable import Readme

/// Answers the checker's one request with what a test gives it, and counts the requests.
private final class FakeGitHub: @unchecked Sendable {
    var reply: Result<Data, Error>
    private(set) var asked: [URL] = []

    init(_ reply: Result<Data, Error>) { self.reply = reply }

    func fetch(_ url: URL) throws -> Data {
        asked.append(url)
        return try reply.get()
    }

    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Result<Data, Error> {
        .success(Data("""
        {"tag_name": "\(tag)", "html_url": "https://github.com/rajanchavda/readme/releases/tag/\(tag)",
         "draft": \(draft), "prerelease": \(prerelease), "body": "notes"}
        """.utf8))
    }
}

private struct Offline: Error {}

@MainActor
@Suite struct UpdateCheckerTests {
    let defaults: UserDefaults
    let suite: String

    init() {
        suite = "com.rajanchavda.Readme.tests.updates.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    private func clean() { defaults.removePersistentDomain(forName: suite) }

    private func checker(_ github: FakeGitHub, current: String = "1.1") -> UpdateChecker {
        UpdateChecker(current: AppVersion(current)!, defaults: defaults) { try github.fetch($0) }
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Versions

    @Test func versionsCompareByNumberNotText() throws {
        #expect(try #require(AppVersion("1.10")) > #require(AppVersion("1.9")))
        #expect(try #require(AppVersion("v1.2")) > #require(AppVersion("1.1")))
        #expect(AppVersion("1.1") == AppVersion("v1.1.0"))
        #expect(try #require(AppVersion("2")) > #require(AppVersion("1.9.9")))
        #expect(AppVersion("v1.1")?.description == "1.1")
    }

    @Test func nonsenseIsNotAVersion() {
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("1.2-beta") == nil)
    }

    // MARK: Checking

    @Test func aNewerReleaseIsFound() async {
        defer { clean() }
        let github = FakeGitHub(FakeGitHub.release("v1.2"))
        let result = await checker(github).check(now: start)
        #expect(result == .newer(Release(
            version: AppVersion("1.2")!,
            page: URL(string: "https://github.com/rajanchavda/readme/releases/tag/v1.2")!)))
        #expect(github.asked == [UpdateChecker.latestRelease])
    }

    @Test func theSameOrOlderReleaseIsUpToDate() async {
        defer { clean() }
        #expect(await checker(FakeGitHub(FakeGitHub.release("v1.1"))).check(now: start) == .upToDate)
        #expect(await checker(FakeGitHub(FakeGitHub.release("v1.0"))).check(now: start) == .upToDate)
    }

    @Test func draftsAndPrereleasesAreIgnored() async {
        defer { clean() }
        #expect(await checker(FakeGitHub(FakeGitHub.release("v2.0", prerelease: true))).check(now: start) == .upToDate)
        #expect(await checker(FakeGitHub(FakeGitHub.release("v2.0", draft: true))).check(now: start) == .upToDate)
    }

    @Test func noAnswerOrAStrangeOneFails() async {
        defer { clean() }
        #expect(await checker(FakeGitHub(.failure(Offline()))).check(now: start) == .failed)
        #expect(await checker(FakeGitHub(.success(Data("<html>".utf8)))).check(now: start) == .failed)
        #expect(await checker(FakeGitHub(FakeGitHub.release("nightly"))).check(now: start) == .failed)
    }

    // MARK: Checking automatically

    @Test func theQuestionComesOnTheSecondLaunch() {
        defer { clean() }
        let updates = checker(FakeGitHub(.failure(Offline())))
        updates.noteLaunch()
        #expect(!updates.shouldAskAboutAutomatic)
        updates.noteLaunch()
        #expect(updates.shouldAskAboutAutomatic)
        updates.automatic = false
        #expect(!updates.shouldAskAboutAutomatic)
        updates.noteLaunch()
        #expect(!updates.shouldAskAboutAutomatic)
    }

    @Test func theAnswerIsRemembered() {
        defer { clean() }
        checker(FakeGitHub(.failure(Offline()))).automatic = true
        #expect(checker(FakeGitHub(.failure(Offline()))).automatic == true)
    }

    @Test func automaticChecksAreDueOnceADay() async {
        defer { clean() }
        let updates = checker(FakeGitHub(FakeGitHub.release("v1.1")))
        #expect(!updates.isDue(now: start))
        updates.automatic = true
        #expect(updates.isDue(now: start))
        _ = await updates.check(now: start)
        #expect(!updates.isDue(now: start.addingTimeInterval(23 * 3600)))
        #expect(updates.isDue(now: start.addingTimeInterval(24 * 3600)))
        updates.automatic = false
        #expect(!updates.isDue(now: start.addingTimeInterval(48 * 3600)))
    }

    @Test func aFailedCheckIsTriedAgainSoon() async {
        defer { clean() }
        let updates = checker(FakeGitHub(.failure(Offline())))
        updates.automatic = true
        _ = await updates.check(now: start)
        #expect(updates.isDue(now: start.addingTimeInterval(3600)))
    }

    @Test func aDeclinedVersionIsOnlyShownWhenAsked() {
        defer { clean() }
        let updates = checker(FakeGitHub(.failure(Offline())))
        let release = Release(version: AppVersion("1.2")!, page: URL(string: "https://example.com")!)
        #expect(updates.shouldShow(release, automatically: true))
        updates.decline(release)
        #expect(!updates.shouldShow(release, automatically: true))
        #expect(updates.shouldShow(release, automatically: false))
        let later = Release(version: AppVersion("1.3")!, page: URL(string: "https://example.com")!)
        #expect(updates.shouldShow(later, automatically: true))
    }
}
