import Foundation

/// A release number such as `1.1` or `v1.2.3`, compared number by number, so 1.10 comes after 1.9.
/// Missing places count as zero: 1.1 and 1.1.0 are the same.
struct AppVersion: Comparable, Hashable, CustomStringConvertible, Sendable {
    let parts: [Int]

    init?(_ text: String) {
        let digits = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let pieces = digits.split(separator: ".", omittingEmptySubsequences: false)
        let parts = pieces.compactMap { piece in piece.allSatisfy(\.isASCII) ? Int(piece) : nil }
        guard !pieces.isEmpty, parts.count == pieces.count, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        self.parts = parts
    }

    /// The version of the app that's running.
    static let running = AppVersion(
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion("0")!

    private var trimmed: [Int] {
        var parts = parts
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    var description: String { trimmed.map(String.init).joined(separator: ".") }

    static func == (a: Self, b: Self) -> Bool { a.trimmed == b.trimmed }
    func hash(into hasher: inout Hasher) { hasher.combine(trimmed) }

    static func < (a: Self, b: Self) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}

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

    static let latestRelease = URL(string: "https://api.github.com/repos/rajanchavda/readme/releases/latest")!
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
              let latest = Self.release(from: data) else { return .failed }
        defaults.set(now, forKey: Key.lastChecked)
        guard let latest, latest.version > current else { return .upToDate }
        return .newer(latest)
    }

    /// An automatic check stays quiet about a version the reader turned down. Asking always shows it.
    func shouldShow(_ release: Release, automatically: Bool) -> Bool {
        !automatically || defaults.string(forKey: Key.declined) != release.version.description
    }

    func decline(_ release: Release) {
        defaults.set(release.version.description, forKey: Key.declined)
    }

    /// The release GitHub described, `.some(nil)` for a draft or prerelease (nothing to offer), or
    /// nil if the answer can't be read.
    private static func release(from data: Data) -> Release?? {
        struct Answer: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let version = AppVersion(answer.tag_name) else { return nil }
        if answer.draft == true || answer.prerelease == true { return .some(nil) }
        return .some(Release(version: version, page: answer.html_url))
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
