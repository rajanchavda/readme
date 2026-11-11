import Foundation

/// Readme's latest release, as GitHub's API describes it: its version, its page, and the disk image
/// and checksum attached to it. Assets are only taken from Readme's own release downloads on
/// github.com, so a changed answer can't point the updater anywhere else.
struct LatestRelease: Equatable, Sendable {
    static let api = URL(string: "https://api.github.com/repos/rajanchavda/readme/releases/latest")!
    static let downloads = "/rajanchavda/readme/releases/download/"

    let version: AppVersion
    let page: URL
    /// False for a draft or a prerelease, which are never offered.
    let isPublished: Bool
    let disk: URL?
    let checksum: URL?

    static func decode(_ data: Data) -> LatestRelease? {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        struct Answer: Decodable {
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let version = AppVersion(answer.tag_name) else { return nil }
        func asset(_ name: String) -> URL? {
            answer.assets?.first { $0.name == name }.map(\.browser_download_url).flatMap { url in
                url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix(downloads) ? url : nil
            }
        }
        let disk = "Readme-\(version).dmg"
        return LatestRelease(
            version: version, page: answer.html_url,
            isPublished: answer.draft != true && answer.prerelease != true,
            disk: asset(disk), checksum: asset(disk + ".sha256"))
    }
}
