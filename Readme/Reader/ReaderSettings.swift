import Foundation

enum ThemeChoice: String, Codable, CaseIterable { case auto, paper, sepia, night }

enum Theme { case paper, sepia, night }

enum BookFont: String, Codable, CaseIterable { case ebGaramond, literata, newYork }

/// How many characters a line holds, on average.
enum LineWidth: String, Codable, CaseIterable {
    case narrow, regular, wide

    var characters: Double {
        switch self {
        case .narrow: 45
        case .regular: 52
        case .wide: 60
        }
    }
}

struct ReaderSettings: Codable, Equatable {
    var theme: ThemeChoice = .auto
    var font: BookFont = .ebGaramond
    var fontSize: Double = 18
    var lineWidth: LineWidth = .regular

    static let key = "readerSettings"

    /// Where the settings are kept. Tests run in several copies of the app at once, so each copy
    /// keeps its own and none changes the settings under another, or the reader's real ones.
    /// `UserDefaults` is safe to share between threads, though it isn't marked so.
    nonisolated(unsafe) static let store: UserDefaults = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil else { return .standard }
        let name = "com.rajanchavda.Readme.tests.\(environment["README_TEST_SHARD"] ?? "0")"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()

    /// What was saved, or the defaults if nothing was or it can't be read.
    static func load(_ defaults: UserDefaults = store) -> Self {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(_ defaults: UserDefaults = store) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func resolvedTheme(systemIsDark: Bool) -> Theme {
        switch theme {
        case .auto: systemIsDark ? .night : .paper
        case .paper: .paper
        case .sepia: .sepia
        case .night: .night
        }
    }
}
