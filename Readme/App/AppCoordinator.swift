import AppKit
import Combine
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

/// The question an import asks when some of its books are here already.
enum ImportQuestion {
    static func message(existing: Int, total: Int) -> String {
        if total == 1 { return "This book is already in your library." }
        return existing == 1
            ? "1 of these books is already in your library."
            : "\(existing) of these books are already in your library."
    }

    static let informative = "Keep Mine leaves your copy as it is. Combine adds the highlights you don't have and keeps whichever reading place is further along. Your copy of the book is never replaced."
    static let buttons = ["Keep Mine", "Combine", "Cancel"]
}

/// What the menus show as available.
@MainActor
final class AppState: ObservableObject {
    @Published var isShowingLibrary = false
    /// Whether the open book has a reading marker to go to.
    @Published var hasMarker = false
    /// Whether there's anything on the shelf to export.
    @Published var hasBooks = false
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
    /// The books picked out on the shelf.
    let selection = ShelfSelection()
    let exporter: LibraryExporter
    let libraryImporter: LibraryImporter
    /// The books an import under way is combining into, which mustn't be opened until it's done.
    private(set) var combiningIDs: Set<String> = []
    /// Opens waiting for that import to finish.
    private var waitingForCombine: [CheckedContinuation<Void, Never>] = []
    private var watchingBooks: AnyCancellable?
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
        library: LibraryStore, positions: PositionStore, defaults: UserDefaults = ReaderSettings.store, state: AppState = AppState()
    ) {
        self.state = state
        self.library = library
        self.positions = positions
        let importer = BookImporter(store: library)
        self.importer = importer
        drops = ShelfDrops(importAll: { await importer.importAll($0) })
        exporter = LibraryExporter(store: library)
        libraryImporter = LibraryImporter(store: library, importer: importer)
        reader = ReaderWindowController(defaults: defaults, positions: positions, library: library)
        let shelf = NSHostingView(rootView: LibraryView(
            library: library, importer: importer, drops: drops, selection: selection,
            onOpen: { [weak self] book in
                guard let self else { return }
                Task { await self.open(book) }
            },
            onExport: { [weak self] books in
                guard let self else { return }
                Task { await self.export(books) }
            },
            onBundles: { [weak self] urls in
                guard let self else { return }
                Task { await self.importBundles(urls) }
            }))
        shelf.sizingOptions = []
        reader.setLibrary(shelf)
        reader.onShowLibrary = { [weak self] in self?.showLibrary() }
        reader.onRead = { [weak self] id, location in self?.marker.read(id: id, location: location) }
        reader.onShowingLibraryChange = { [weak self] showing in self?.state.isShowingLibrary = showing }
        reader.onMarkerChange = { [weak self] has in self?.state.hasMarker = has }
        reader.onLibraryEscape = { [weak self] in self?.selection.clear() }
        state.hasBooks = !library.books.isEmpty
        watchingBooks = library.$books.sink { [weak state] books in state?.hasBooks = !books.isEmpty }
        library.onRemove = { [weak self] id in
            guard let self else { return }
            // One still waiting to open checks the shelf itself, and mustn't close the book open now.
            if self.openingID == id { self.openingID = nil }
            if self.reader.currentRecordID == id { self.reader.closeBook() }
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
        // Opened now, it would come up on its old place and write that over what the import brings.
        if combiningIDs.contains(book.id) {
            await withCheckedContinuation { waitingForCombine.append($0) }
        }
        marker.flush()
        await reader.open(book, at: cfi)
    }

    func chooseBook() {
        showWindow()
        reader.chooseBook { [weak self] urls in
            guard let self else { return }
            Task {
                if urls.count > 1 {
                    // Several books chosen at once are for the shelf, not for reading one of them.
                    self.reader.showLibrary()
                    await self.drops.add(urls)
                } else {
                    await self.importAndOpen(urls)
                }
            }
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
        let (books, bundles) = LibraryView.split(urls)
        Task {
            if !bundles.isEmpty { await importBundles(bundles) }
            if !books.isEmpty { await importAndOpen(books) }
        }
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

    /// Asks for library bundles and imports them.
    func chooseBundle() {
        showWindow()
        reader.showLibrary()
        reader.chooseBundle { [weak self] urls in
            guard let self else { return }
            Task { await self.importBundles(urls) }
        }
    }

    /// Imports each bundle in turn, over the library. If some of a bundle's books are here already,
    /// the reader is asked what to do with them, unless `answer` is given; its `.some(nil)` is Cancel.
    /// A book open in the reader that's about to be combined is closed first, so nothing it still holds
    /// is written over what the import brings, and it opens next on the place the import left.
    func importBundles(_ urls: [URL], answer: ImportChoice?? = nil) async {
        for url in urls {
            showLibrary()
            let prepared: PreparedImport
            do {
                prepared = try await libraryImporter.prepare(url)
            } catch {
                drops.say(error.message)
                continue
            }
            var choice = ImportChoice.keepMine
            if !prepared.existingIDs.isEmpty {
                let asked: ImportChoice?
                if let answer {
                    asked = answer
                } else {
                    asked = await reader.askImportChoice(
                        existing: prepared.existingIDs.count, total: prepared.bundle.manifest.bookIDs.count)
                }
                guard let asked else { continue }
                choice = asked
            }
            if choice == .combine, let open = reader.currentRecordID, prepared.existingIDs.contains(open) {
                marker.flush()
                await reader.placesKept()
                reader.closeBook()
            }
            if choice == .combine { combiningIDs = Set(prepared.existingIDs) }
            drops.setWorking(ShelfDrops.workingLine("Importing", prepared.bundle.manifest.bookIDs.count))
            let summary = await libraryImporter.run(prepared, choice: choice)
            combiningIDs = []
            let waiting = waitingForCombine
            waitingForCombine = []
            for open in waiting { open.resume() }
            drops.setWorking(nil)
            drops.say(summary.line)
        }
    }

    /// Exports every book on the shelf.
    func exportLibrary() {
        showWindow()
        reader.showLibrary()
        Task { await export(library.books) }
    }

    /// Asks where to save `books`, unless `destination` is given, and writes them there. How it went
    /// is said on the shelf.
    func export(_ books: [Book], destination: URL? = nil) async {
        guard !books.isEmpty else { return }
        let name = books.count == 1 ? books[0].title : "Readme Library"
        var chosen = destination
        if chosen == nil { chosen = await reader.chooseExportDestination(suggestedName: name) }
        guard let url = chosen else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        drops.setWorking(ShelfDrops.workingLine("Exporting", books.count))
        do {
            let summary = try await exporter.export(books, to: url)
            drops.setWorking(nil)
            drops.say(summary.line)
        } catch {
            drops.setWorking(nil)
            drops.say(error.message)
        }
        selection.clear()
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
