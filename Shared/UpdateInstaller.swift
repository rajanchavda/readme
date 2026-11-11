import CryptoKit
import Foundation

/// Why an update couldn't be installed. Each leaves the installed app as it was.
enum InstallError: Error, Equatable {
    case notReadme
    case upToDate
    case noRelease
    case notWritable(String)
    case checksumMismatch
    case cantOpenDisk
    case notTheRelease
    case homebrewFailed(String)
    case swapFailed(String)

    var message: String {
        switch self {
        case .notReadme: "The updater isn't inside a copy of Readme."
        case .upToDate: "Readme is already up to date."
        case .noRelease: "GitHub didn't offer a release that can be installed."
        case let .notWritable(folder): "Readme can't replace itself in \(folder). Check that you can change that folder."
        case .checksumMismatch: "The download didn't match the release's checksum, so nothing was changed."
        case .cantOpenDisk: "The downloaded disk image couldn't be opened."
        case .notTheRelease: "The download didn't hold a signed copy of the expected version, so nothing was changed."
        case let .homebrewFailed(output):
            "Homebrew couldn't upgrade Readme:\n\n\(output)\n\nRun brew upgrade --cask readme in Terminal to see more."
        case let .swapFailed(reason): "The new version couldn't be put in place: \(reason)"
        }
    }
}

/// The parts of updating that reach outside the process, so tests can play them.
struct InstallWorld: Sendable {
    /// Fetches something small: the API's answer, or a checksum file.
    var fetch: @Sendable (URL) async throws -> Data
    /// Downloads a file to a place on disk.
    var download: @Sendable (URL, URL) async throws -> Void
    /// Runs a tool and gives its exit status and what it printed.
    var run: @Sendable (URL, [String]) async throws -> (status: Int32, output: String)
}

/// The identifier and version an app's Info.plist gives, read afresh each time (Bundle caches).
struct AppBundleInfo: Equatable {
    static let readme = "com.rajanchavda.Readme"

    let identifier: String
    let version: AppVersion

    init?(_ app: URL) {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) else { return nil }
        self.identifier = identifier
        self.version = version
    }
}

enum Checksum {
    /// The hash at the start of a `.sha256` file, in lower case, or nil if it doesn't start with one.
    static func parse(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first?.lowercased(),
              first.count == 64, first.allSatisfy(\.isHexDigit) else { return nil }
        return first
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum AppSwap {
    /// Puts a copy of `new` where `app` is. The copy is made beside the app first, then the two are
    /// swapped by renaming, so a failure at any step leaves the old app in place.
    static func replace(_ app: URL, with new: URL) throws {
        let folder = app.deletingLastPathComponent()
        let tag = UUID().uuidString
        let staged = folder.appendingPathComponent(".Readme-update-\(tag).app", isDirectory: true)
        let previous = folder.appendingPathComponent(".Readme-previous-\(tag).app", isDirectory: true)
        let files = FileManager.default
        do {
            try files.copyItem(at: new, to: staged)
        } catch {
            try? files.removeItem(at: staged)
            throw InstallError.swapFailed(error.localizedDescription)
        }
        do {
            try files.moveItem(at: app, to: previous)
        } catch {
            try? files.removeItem(at: staged)
            throw InstallError.swapFailed(error.localizedDescription)
        }
        do {
            try files.moveItem(at: staged, to: app)
        } catch {
            try? files.moveItem(at: previous, to: app)
            try? files.removeItem(at: staged)
            throw InstallError.swapFailed(error.localizedDescription)
        }
        try? files.removeItem(at: previous)
    }
}

enum Homebrew {
    static let roots = [URL(fileURLWithPath: "/opt/homebrew"), URL(fileURLWithPath: "/usr/local")]
    /// Where the cask puts Readme. A copy anywhere else isn't Homebrew's to upgrade.
    static let apps = [
        URL(fileURLWithPath: "/Applications/Readme.app"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Readme.app"),
    ]

    /// The brew that installed Readme's cask, if one did.
    static func find(in roots: [URL] = roots) -> URL? {
        for root in roots {
            let brew = root.appendingPathComponent("bin/brew")
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("Caskroom/readme").path),
               FileManager.default.isExecutableFile(atPath: brew.path) { return brew }
        }
        return nil
    }
}

/// Replaces a Readme.app with GitHub's latest release. It takes no instructions: the app is the
/// one it sits inside, and the version, download and checksum come from GitHub. The copy in
/// Applications, when Homebrew installed Readme, is upgraded with brew, so Homebrew keeps track of
/// it; any other is replaced from the release's disk image, once its checksum, identifier, version
/// and signature check out.
struct UpdateInstaller {
    let app: URL
    var homebrewRoots = Homebrew.roots
    var homebrewApps = Homebrew.apps
    let world: InstallWorld
    /// An empty folder to download and mount into. It's removed when done.
    let scratch: URL

    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    private static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
    private static let xattr = URL(fileURLWithPath: "/usr/bin/xattr")

    /// Installs the latest release and gives its version.
    func install() async throws -> AppVersion {
        guard let installed = AppBundleInfo(app), installed.identifier == AppBundleInfo.readme else {
            throw InstallError.notReadme
        }
        guard let release = LatestRelease.decode(try await world.fetch(LatestRelease.api)),
              release.isPublished else { throw InstallError.noRelease }
        guard release.version > installed.version else { throw InstallError.upToDate }

        if homebrewApps.contains(where: { $0.standardizedFileURL == app.standardizedFileURL }),
           let brew = Homebrew.find(in: homebrewRoots) {
            return try await upgrade(with: brew, to: release.version)
        }
        return try await replace(with: release)
    }

    private func upgrade(with brew: URL, to version: AppVersion) async throws -> AppVersion {
        let (status, output) = try await world.run(brew, ["upgrade", "--cask", "readme"])
        guard status == 0 else {
            throw InstallError.homebrewFailed(String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)))
        }
        guard let now = AppBundleInfo(app), now.version >= version else {
            throw InstallError.homebrewFailed("Homebrew didn't install Readme \(version).")
        }
        return now.version
    }

    private func replace(with release: LatestRelease) async throws -> AppVersion {
        guard let disk = release.disk, let checksum = release.checksum else { throw InstallError.noRelease }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw InstallError.notWritable(folder.path)
        }
        guard let expected = Checksum.parse(String(decoding: try await world.fetch(checksum), as: UTF8.self)) else {
            throw InstallError.noRelease
        }

        let files = FileManager.default
        try? files.removeItem(at: scratch)
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        let image = scratch.appendingPathComponent("Readme.dmg")
        try await world.download(disk, image)
        guard try Checksum.sha256(ofFile: image) == expected else { throw InstallError.checksumMismatch }

        let mount = scratch.appendingPathComponent("mount", isDirectory: true)
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try await world.run(Self.hdiutil, [
            "attach", image.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path,
        ])
        guard attach.status == 0 else { throw InstallError.cantOpenDisk }

        do {
            let new = mount.appendingPathComponent("Readme.app", isDirectory: true)
            guard AppBundleInfo(new) == AppBundleInfo(identifier: AppBundleInfo.readme, version: release.version),
                  try await world.run(Self.codesign, ["--verify", "--strict", "--deep", new.path]).status == 0 else {
                throw InstallError.notTheRelease
            }
            try AppSwap.replace(app, with: new)
        } catch {
            _ = try? await world.run(Self.hdiutil, ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await world.run(Self.hdiutil, ["detach", mount.path, "-force"])
        // Nothing here downloads with quarantine, but a copy that picked it up mustn't be blocked.
        _ = try? await world.run(Self.xattr, ["-dr", "com.apple.quarantine", app.path])
        return release.version
    }
}

extension AppBundleInfo {
    init(identifier: String, version: AppVersion) {
        self.identifier = identifier
        self.version = version
    }
}
