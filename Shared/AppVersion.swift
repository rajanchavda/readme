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
