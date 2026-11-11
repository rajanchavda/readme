import Foundation
import SwiftUI

/// What happens when files are dropped on the shelf: they're imported, and what went wrong is kept as a
/// quiet notice that fades by itself. Drops that overlap share one notice, and each failure restarts
/// the fade.
@MainActor
final class ShelfDrops: ObservableObject {
    /// One line for each kind of failure that's showing.
    @Published private(set) var notice: [ImportError] = []
    /// How many files are still being added, once that has taken long enough to be worth saying.
    @Published private(set) var adding = 0
    /// A line of its own, such as how an export went, shown and faded like a failure.
    @Published private(set) var message: String?
    /// What's under way, such as an export, said while it lasts.
    @Published private(set) var working: String?
    private var pending = 0
    private var fading: Task<Void, Never>?

    private let importAll: ([URL]) async -> [Result<Book, ImportError>]
    private let noticeDuration: Duration
    private let progressDelay: Duration

    init(
        noticeDuration: Duration = .seconds(4), progressDelay: Duration = .milliseconds(500),
        importAll: @escaping ([URL]) async -> [Result<Book, ImportError>]
    ) {
        self.noticeDuration = noticeDuration
        self.progressDelay = progressDelay
        self.importAll = importAll
    }

    /// Imports `files`. Books already in the library come back as successes, and aren't a problem.
    @discardableResult
    func add(_ files: [URL]) async -> [Result<Book, ImportError>] {
        guard !files.isEmpty else { return [] }
        pending += files.count
        let count = files.count
        let delay = progressDelay
        let waiting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.pending > 0 else { return }
            self.adding = self.pending
        }
        let results = await importAll(files)
        waiting.cancel()
        pending -= count
        adding = adding > 0 ? pending : 0
        let failures = results.compactMap { result -> ImportError? in
            if case .failure(let error) = result { return error }
            return nil
        }
        if !failures.isEmpty { show(failures) }
        return results
    }

    /// Shows a failure from elsewhere, such as a book on the shelf that couldn't be opened.
    func show(_ failures: [ImportError]) {
        guard !failures.isEmpty else { return }
        for error in failures where !notice.contains(error) { notice.append(error) }
        fade()
    }

    /// Shows `line`, replacing the one shown before, and fades it with any failures showing.
    func say(_ line: String) {
        message = line
        fade()
    }

    func setWorking(_ line: String?) {
        working = line
    }

    /// "Exporting 12 books…", or "…1 book…".
    static func workingLine(_ verb: String, _ count: Int) -> String {
        count == 1 ? "\(verb) 1 book…" : "\(verb) \(count) books…"
    }

    private func fade() {
        fading?.cancel()
        let duration = noticeDuration
        fading = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.notice = []
            self?.message = nil
        }
    }

    /// The line for each kind that's showing, then the message, if there is one.
    var lines: [String] { notice.map(Self.message(for:)) + [message].compactMap { $0 } }

    static func message(for error: ImportError) -> String {
        switch error {
        case .copyProtected: "This book is copy-protected, so it can't be opened here."
        case .notAnEPUB: "This file isn't an EPUB book."
        case .unreadable: "This book couldn't be read."
        }
    }

    /// One line for each kind of failure, in the order they first happened.
    static func messages(for errors: [ImportError]) -> [String] {
        var seen: [ImportError] = []
        for error in errors where !seen.contains(error) { seen.append(error) }
        return seen.map(message(for:))
    }

    static func progressLine(_ count: Int) -> String {
        count == 1 ? "Adding a book…" : "Adding \(count) books…"
    }

    /// For checking how a notice looks.
    func showForPreview(_ errors: [ImportError]) { notice = errors }
}
