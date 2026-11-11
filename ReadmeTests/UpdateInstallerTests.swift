import Foundation
import Testing
@testable import Readme

/// A pretend Readme.app: an Info.plist with an identifier and version, and a binary to tell it by.
private func makeApp(at url: URL, version: String, id: String = "com.rajanchavda.Readme") throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(
        at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try Data("readme \(version)".utf8).write(to: contents.appendingPathComponent("MacOS/Readme"))
}

private func binary(of app: URL) -> String? {
    try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/Readme"), encoding: .utf8)
}

private let api = LatestRelease.api
private let base = "https://github.com/rajanchavda/readme/releases/download"

private func releaseJSON(_ version: String, assetBase: String = base) -> Data {
    Data("""
    {"tag_name": "v\(version)", "html_url": "https://github.com/rajanchavda/readme/releases/tag/v\(version)",
     "draft": false, "prerelease": false,
     "assets": [
       {"name": "Readme-\(version).dmg", "browser_download_url": "\(assetBase)/v\(version)/Readme-\(version).dmg"},
       {"name": "Readme-\(version).dmg.sha256", "browser_download_url": "\(assetBase)/v\(version)/Readme-\(version).dmg.sha256"}
     ]}
    """.utf8)
}

/// GitHub, hdiutil, codesign and brew, played by the test. Records what was run.
private final class FakeWorld: @unchecked Sendable {
    let folder: URL
    var latest = "1.3"
    var diskBytes = Data("the disk image".utf8)
    var publishedChecksum: String?
    /// The version of the Readme.app inside the disk image.
    var diskAppVersion: String?
    var codesignStatus: Int32 = 0
    var brewStatus: Int32 = 0
    /// What brew does to the app when it runs, if it succeeds.
    var brewInstalls: ((URL) throws -> Void)?
    var app: URL?
    private(set) var ran: [[String]] = []
    private(set) var downloaded: [URL] = []

    init(folder: URL) { self.folder = folder }

    var world: InstallWorld {
        InstallWorld(
            fetch: { url in try self.fetch(url) },
            download: { url, file in try self.download(url, to: file) },
            run: { tool, arguments in try self.run(tool, arguments) })
    }

    private func fetch(_ url: URL) throws -> Data {
        if url == api { return releaseJSON(latest) }
        if url.lastPathComponent.hasSuffix(".sha256") {
            let sum = publishedChecksum ?? Checksum.sha256(of: diskBytes)
            return Data("\(sum)  Readme-\(latest).dmg\n".utf8)
        }
        throw URLError(.fileDoesNotExist)
    }

    private func download(_ url: URL, to file: URL) throws {
        downloaded.append(url)
        try diskBytes.write(to: file)
    }

    private func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        ran.append([tool.lastPathComponent] + arguments)
        switch tool.lastPathComponent {
        case "hdiutil" where arguments.first == "attach":
            let index = try #require(arguments.firstIndex(of: "-mountpoint"))
            let mount = URL(fileURLWithPath: arguments[index + 1])
            try makeApp(at: mount.appendingPathComponent("Readme.app"), version: diskAppVersion ?? latest)
            return (0, "")
        case "hdiutil": return (0, "")
        case "codesign": return (codesignStatus, codesignStatus == 0 ? "" : "invalid signature")
        case "xattr": return (0, "")
        case "brew":
            if brewStatus == 0, let app { try brewInstalls?(app) }
            return (brewStatus, brewStatus == 0 ? "" : "Error: it went wrong")
        default: return (127, "unknown tool")
        }
    }
}

@Suite(.serialized) struct UpdateInstallerTests {
    let folder: URL
    let app: URL
    private let fake: FakeWorld

    init() throws {
        folder = try libraryFolder()
        app = folder.appendingPathComponent("Applications/Readme.app", isDirectory: true)
        try makeApp(at: app, version: "1.2")
        fake = FakeWorld(folder: folder)
        fake.app = app
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    private func installer(homebrew: Bool = false, homebrewManagesThisCopy: Bool = true) throws -> UpdateInstaller {
        let root = folder.appendingPathComponent("homebrew", isDirectory: true)
        if homebrew {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Caskroom/readme"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: root.appendingPathComponent("bin/brew").path, contents: Data(),
                attributes: [.posixPermissions: 0o755])
        }
        return UpdateInstaller(
            app: app, homebrewRoots: [root], homebrewApps: homebrewManagesThisCopy ? [app] : [],
            world: fake.world,
            scratch: folder.appendingPathComponent("scratch", isDirectory: true))
    }

    // MARK: The release

    @Test func theReleaseNamesItsDiskImageAndChecksum() throws {
        let release = try #require(LatestRelease.decode(releaseJSON("1.3")))
        #expect(release.version == AppVersion("1.3"))
        #expect(release.isPublished)
        #expect(release.disk == URL(string: "\(base)/v1.3/Readme-1.3.dmg"))
        #expect(release.checksum == URL(string: "\(base)/v1.3/Readme-1.3.dmg.sha256"))
    }

    @Test func assetsFromAnywhereElseAreIgnored() throws {
        let release = try #require(LatestRelease.decode(
            releaseJSON("1.3", assetBase: "https://example.com/rajanchavda/readme/releases/download")))
        #expect(release.disk == nil)
        #expect(release.checksum == nil)
        let other = try #require(LatestRelease.decode(
            releaseJSON("1.3", assetBase: "https://github.com/someone/else/releases/download")))
        #expect(other.disk == nil)
    }

    // MARK: Checksums

    @Test func checksumsAreReadFromTheSha256File() {
        let sum = String(repeating: "ab", count: 32)
        #expect(Checksum.parse("\(sum)  Readme-1.3.dmg\n") == sum)
        #expect(Checksum.parse(sum.uppercased()) == sum)
        #expect(Checksum.parse("not a checksum") == nil)
        #expect(Checksum.parse("") == nil)
    }

    @Test func sha256OfKnownText() throws {
        #expect(Checksum.sha256(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        defer { clean() }
        let file = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try Checksum.sha256(ofFile: file) == Checksum.sha256(of: Data("abc".utf8)))
    }

    // MARK: Swapping the app

    @Test func swappingReplacesTheAppAndLeavesNothingBehind() throws {
        defer { clean() }
        let new = folder.appendingPathComponent("new/Readme.app")
        try makeApp(at: new, version: "1.3")
        try AppSwap.replace(app, with: new)
        #expect(binary(of: app) == "readme 1.3")
        let left = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(left == ["Readme.app"])
    }

    @Test func aFailedSwapKeepsTheOldApp() throws {
        defer { clean() }
        #expect(throws: (any Error).self) {
            try AppSwap.replace(app, with: folder.appendingPathComponent("missing/Readme.app"))
        }
        #expect(binary(of: app) == "readme 1.2")
        let left = try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)
        #expect(left == ["Readme.app"])
    }

    // MARK: Installing from the disk image

    @Test func aNewerReleaseIsDownloadedCheckedAndInstalled() async throws {
        defer { clean() }
        #expect(try await installer().install() == AppVersion("1.3"))
        #expect(binary(of: app) == "readme 1.3")
        #expect(fake.downloaded == [URL(string: "\(base)/v1.3/Readme-1.3.dmg")!])
        #expect(fake.ran.contains { $0.first == "codesign" })
        #expect(fake.ran.contains { $0.prefix(2) == ["hdiutil", "detach"] })
        #expect(!fake.ran.contains { $0.first == "brew" })
    }

    @Test func aDiskImageThatDoesntMatchItsChecksumIsRefused() async throws {
        defer { clean() }
        fake.publishedChecksum = String(repeating: "0", count: 64)
        await #expect(throws: InstallError.checksumMismatch) { try await installer().install() }
        #expect(binary(of: app) == "readme 1.2")
        #expect(!fake.ran.contains { $0.first == "hdiutil" })
    }

    @Test func theWrongAppInTheDiskImageIsRefused() async throws {
        defer { clean() }
        fake.diskAppVersion = "1.1"
        await #expect(throws: InstallError.notTheRelease) { try await installer().install() }
        #expect(binary(of: app) == "readme 1.2")
        #expect(fake.ran.contains { $0.prefix(2) == ["hdiutil", "detach"] })
    }

    @Test func anUnsignedAppIsRefused() async throws {
        defer { clean() }
        fake.codesignStatus = 1
        await #expect(throws: InstallError.notTheRelease) { try await installer().install() }
        #expect(binary(of: app) == "readme 1.2")
    }

    @Test func nothingHappensWhenItsAlreadyTheLatest() async throws {
        defer { clean() }
        fake.latest = "1.2"
        await #expect(throws: InstallError.upToDate) { try await installer().install() }
        #expect(fake.downloaded.isEmpty)
    }

    @Test func onlyReadmeIsReplaced() async throws {
        defer { clean() }
        try FileManager.default.removeItem(at: app)
        try makeApp(at: app, version: "1.2", id: "com.example.Other")
        await #expect(throws: InstallError.notReadme) { try await installer().install() }
        #expect(fake.downloaded.isEmpty)
    }

    // MARK: Installing with Homebrew

    @Test func homebrewInstallsUpgradeWithBrew() async throws {
        defer { clean() }
        fake.brewInstalls = { app in
            try FileManager.default.removeItem(at: app)
            try makeApp(at: app, version: "1.3")
        }
        #expect(try await installer(homebrew: true).install() == AppVersion("1.3"))
        #expect(fake.ran.contains(["brew", "upgrade", "--cask", "readme"]))
        #expect(fake.downloaded.isEmpty)
    }

    /// Homebrew only looks after the copy in Applications. Any other copy is replaced directly.
    @Test func aCopyElsewhereIsntLeftToHomebrew() async throws {
        defer { clean() }
        #expect(try await installer(homebrew: true, homebrewManagesThisCopy: false).install() == AppVersion("1.3"))
        #expect(!fake.ran.contains { $0.first == "brew" })
        #expect(binary(of: app) == "readme 1.3")
    }

    @Test func aFailedBrewSaysWhy() async throws {
        defer { clean() }
        fake.brewStatus = 1
        await #expect(throws: InstallError.homebrewFailed("Error: it went wrong")) {
            try await installer(homebrew: true).install()
        }
        #expect(binary(of: app) == "readme 1.2")
    }

    @Test func brewThatChangesNothingIsAFailure() async throws {
        defer { clean() }
        await #expect(throws: InstallError.homebrewFailed("Homebrew didn't install Readme 1.3.")) {
            try await installer(homebrew: true).install()
        }
    }

    @Test func errorMessages() {
        #expect(InstallError.checksumMismatch.message
            == "The download didn't match the release's checksum, so nothing was changed.")
        #expect(InstallError.homebrewFailed("Error: x").message
            == "Homebrew couldn't upgrade Readme:\n\nError: x\n\nRun brew upgrade --cask readme in Terminal to see more.")
    }
}
