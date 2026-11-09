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

    /// What was saved, or the defaults if nothing was or it can't be read.
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
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
