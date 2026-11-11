import Foundation

/// A published release on GitHub, and the page to download it from.
struct Release: Equatable, Sendable {
    let version: AppVersion
    let page: URL
}

enum UpdateCheck: Equatable, Sendable {
    case newer(Release)
    case upToDate
    case failed
}

/// Asks GitHub for Readme's latest release and says whether it's newer than this copy. It asks for
/// nothing else and sends nothing about the reader or their books. It also keeps whether to check
/// on its own, about once a day, and which version the reader has already said "Not Now" to.
@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let latestRelease = LatestRelease.api
    static let interval: TimeInterval = 24 * 3600

    private enum Key {
        static let automatic = "updates.automatic"
        static let launches = "updates.launches"
        static let lastChecked = "updates.lastChecked"
        static let declined = "updates.declined"
    }

    let current: AppVersion
    private let defaults: UserDefaults
    private let fetch: Fetch

    /// Whether to check on its own. Nil until the reader has been asked, or has chosen in the menu.
    @Published var automatic: Bool? {
        didSet {
            if let automatic { defaults.set(automatic, forKey: Key.automatic) }
            else { defaults.removeObject(forKey: Key.automatic) }
        }
    }

    init(current: AppVersion = .running, defaults: UserDefaults, fetch: @escaping Fetch = UpdateChecker.download) {
        self.current = current
        self.defaults = defaults
        self.fetch = fetch
        automatic = defaults.object(forKey: Key.automatic) as? Bool
    }

    func noteLaunch() {
        defaults.set(defaults.integer(forKey: Key.launches) + 1, forKey: Key.launches)
    }

    /// Asked on the second launch rather than the first, so a new reader meets their books first.
    var shouldAskAboutAutomatic: Bool {
        automatic == nil && defaults.integer(forKey: Key.launches) >= 2
    }

    /// Whether an automatic check is due: they're on, and the last one that got an answer was a day
    /// ago or more. A check that failed doesn't count, so it's tried again at the next chance.
    func isDue(now: Date) -> Bool {
        guard automatic == true else { return false }
        let last = defaults.object(forKey: Key.lastChecked) as? Date
        return last.map { now.timeIntervalSince($0) >= Self.interval } ?? true
    }

    func check(now: Date) async -> UpdateCheck {
        guard let data = try? await fetch(Self.latestRelease),
              let latest = LatestRelease.decode(data) else { return .failed }
        defaults.set(now, forKey: Key.lastChecked)
        guard latest.isPublished, latest.version > current else { return .upToDate }
        return .newer(Release(version: latest.version, page: latest.page))
    }

    /// An automatic check stays quiet about a version the reader turned down. Asking always shows it.
    func shouldShow(_ release: Release, automatically: Bool) -> Bool {
        !automatically || defaults.string(forKey: Key.declined) != release.version.description
    }

    func decline(_ release: Release) {
        defaults.set(release.version.description, forKey: Key.declined)
    }

    /// The request itself: no cookies, no cache, nothing remembered between checks.
    nonisolated static let download: Fetch = { url in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
