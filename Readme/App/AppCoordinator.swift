import AppKit
import SwiftUI

/// Tells the library where the reader is, so the shelf's "Continue reading" and the next launch are
/// right, without rewriting the library file on every page: a book's first place is passed on at once,
/// and after that at most once an `interval`, the newest place waiting until then. Another book's place
/// is passed on at once, after the first book's last.
@MainActor
final class ReadMarker {
    private let interval: Duration
    private let mark: (String, ReaderLocation) -> Void
    private var pending: (id: String, location: ReaderLocation)?
    private var lastMarked: (id: String, at: ContinuousClock.Instant)?
    private var timer: Task<Void, Never>?

    init(interval: Duration = .seconds(2), mark: @escaping (String, ReaderLocation) -> Void) {
        self.interval = interval
        self.mark = mark
    }

    func read(id: String, location: ReaderLocation) {
        if let pending, pending.id != id { flush() }
        pending = (id, location)
        guard let lastMarked, lastMarked.id == id else {
            flush()
            return
        }
        let since = lastMarked.at.duration(to: .now)
        if since >= interval {
            flush()
        } else if timer == nil {
            let wait = interval - since
            timer = Task { [weak self] in
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    /// Passes on the place waiting, if there is one, now.
    func flush() {
        timer?.cancel()
        timer = nil
        guard let pending else { return }
        self.pending = nil
        lastMarked = (pending.id, .now)
        mark(pending.id, pending.location)
    }
}

/// What the menus show as available.
@MainActor
final class AppState: ObservableObject {
    @Published var isShowingLibrary = false
}

/// The app's one window and what it shows: the library, or a book. It decides where launching goes,
/// opens books from the shelf, the Open panel and the Dock, and waits for everything to be written
/// as the app quits.
@MainActor
final class AppCoordinator {
    let library: LibraryStore
    let importer: BookImporter
    let drops: ShelfDrops
    let reader: ReaderWindowController
    private let positions: PositionStore
    private lazy var marker = ReadMarker { [weak library] id, location in
        library?.markRead(id: id, location: location)
    }
    private var hasLaunched = false
    /// The book being opened, from the moment it's asked for until it has landed or failed.
    private var openingID: String?
    /// What the menus need to know.
    let state: AppState

    init(
        library: LibraryStore, positions: PositionStore, defaults: UserDefaults = .standard, state: AppState = AppState()
    ) {
        self.state = state
        self.library = library
        self.positions = positions
        let importer = BookImporter(store: library)
        self.importer = importer
        drops = ShelfDrops(importAll: { await importer.importAll($0) })
        reader = ReaderWindowController(defaults: defaults, positions: positions, library: library)
        let shelf = NSHostingView(rootView: LibraryView(
            library: library, importer: importer, drops: drops,
            onOpen: { [weak self] book in
                guard let self else { return }
                Task { await self.open(book) }
            }))
        shelf.sizingOptions = []
        reader.setLibrary(shelf)
        reader.onShowLibrary = { [weak self] in self?.showLibrary() }
        reader.onRead = { [weak self] id, location in self?.marker.read(id: id, location: location) }
        reader.onShowingLibraryChange = { [weak self] showing in self?.state.isShowingLibrary = showing }
        library.onRemove = { [weak self] id in
            guard let self, self.reader.currentRecordID == id || self.openingID == id else { return }
            self.openingID = nil
            self.reader.closeBook()
        }
        library.beforeDeleting = { [weak self] in await self?.reader.placesKept() }
        reader.onOpenFailed = { [weak self] _ in
            guard let self else { return }
            self.showLibrary()
            self.drops.show([.unreadable])
        }
    }

    static func standard(state: AppState) -> AppCoordinator {
        AppCoordinator(library: .standard, positions: .standard, state: state)
    }

    var isShowingLibrary: Bool { reader.isShowingLibrary }

    /// Drops the books whose files have gone, quietly, and decides where launching goes.
    func prepareLaunch() -> LaunchRoute {
        let fileExists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        library.removeMissing(fileExists: fileExists)
        var places: [String: ReaderLocation] = [:]
        if let current = library.current, let place = positions.locationNow(bookID: current.id) {
            places[current.id] = place
        }
        return LaunchRoute.resolve(library: library, positions: places, fileExists: fileExists)
    }

    /// Shows the window straight away: on the last spread of the book last read, which opens beneath
    /// it, or on the library.
    func launch() {
        guard !hasLaunched else { return }
        hasLaunched = true
        switch prepareLaunch() {
        case .library:
            reader.showLibrary(animated: false)
            reader.show()
        case let .read(book, cfi):
            reader.showLastSpread(of: book)
            reader.show()
            Task { await open(book, at: cfi) }
        }
    }

    /// Brings the window back as it was left, as clicking the Dock icon does.
    func showWindow() {
        if !hasLaunched {
            launch()
        } else {
            reader.show()
        }
    }

    func showLibrary() {
        marker.flush()
        reader.showLibrary()
    }

    /// Opens `book` in the window, at `cfi` or where it was left. The book that's open already only
    /// has the library taken from over it, one that's still opening is left to finish, and another
    /// one has its place kept first.
    func open(_ book: Book, at cfi: String? = nil) async {
        if cfi == nil, openingID == book.id { return }
        if cfi == nil, reader.openBook?.id == book.id {
            reader.showBook()
            return
        }
        openingID = book.id
        defer { if openingID == book.id { openingID = nil } }
        marker.flush()
        await reader.open(book, at: cfi)
    }

    func chooseBook() {
        showWindow()
        reader.chooseBook { [weak self] url in
            guard let self else { return }
            Task { await self.importAndOpen([url]) }
        }
    }

    /// Books given to the app from outside it, as by dropping them on the Dock icon: they're added to
    /// the library and the first is opened. One that can't be added gets a quiet line, never a dialog.
    func open(_ urls: [URL]) {
        if !hasLaunched {
            // Straight to the library, not the last book, which would only be replaced.
            hasLaunched = true
            _ = prepareLaunch()
            reader.showLibrary(animated: false)
        }
        reader.show()
        Task { await importAndOpen(urls) }
    }

    private func importAndOpen(_ urls: [URL]) async {
        let results: [Result<Book, ImportError>]
        if reader.isShowingLibrary {
            results = await drops.add(urls)
        } else {
            results = await importer.importAll(urls)
            let failures = results.compactMap { result -> ImportError? in
                if case .failure(let error) = result { return error }
                return nil
            }
            let lines = ShelfDrops.messages(for: failures)
            if !lines.isEmpty { reader.showNotice(lines.joined(separator: "\n")) }
        }
        for result in results {
            if case .success(let book) = result {
                await open(book)
                return
            }
        }
    }

    /// The reader's place, the library and the last spread, all written. The app waits for this as
    /// it quits.
    func prepareToQuit() async {
        // The places first, and the picture of the spread, which can be slow, last.
        await reader.placesKept()
        marker.flush()
        await library.saved()
        await library.removed()
        await reader.keepPlace()
    }
}
