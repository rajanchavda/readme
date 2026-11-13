import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

private func scratchDefaults() -> UserDefaults {
    let name = "StaleBookTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// Puts a fixture in `library` as an import would, without reading it in a web view.
@MainActor
func shelve(_ name: String, in library: LibraryStore, read: Date? = nil) async throws -> Book {
    let url = try fixture(name)
    let id = try await BookID.of(url)
    let book = Book(
        id: id, title: name, author: nil, fileName: id + ".epub", hasCover: false, addedAt: Date(),
        lastReadAt: read, chapterTitle: nil, chapterMinutesLeft: nil)
    try FileManager.default.createDirectory(at: library.booksDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: url, to: library.fileURL(for: book))
    library.add(book)
    return book
}

/// A tiny image to stand in for a spread.
func spreadImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.8, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
    return try #require(context.makeImage())
}

/// Books that have changed under the app: a place that's gone from the book, a file that's gone, and
/// a file that's no longer a book.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct StaleBookTests {
    @Test func aSavedPlaceNoLongerInTheBookOpensAtItsFraction() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let lost = ReaderLocation(
            cfi: "epubcfi(/6/999!/4/2/1:0)", fraction: 0.5, chapterTitle: nil, chapterMinutesLeft: 3,
            isAtStart: false, isAtEnd: false, page: 50, pageCount: 100)
        await positions.save(lost, bookID: book.id)

        let reader = ReaderWindowController(defaults: scratchDefaults(), positions: positions, library: library)
        defer { reader.window?.close() }
        reader.window?.setFrameAutosaveName("")
        await reader.open(book)
        await reader.settled()
        let here = try #require(reader.location)
        #expect(abs(here.fraction - 0.5) < 0.05, "Opened at \(here.fraction)")
        // And that's now the place kept for it.
        await reader.keepPlace()
        let kept = try #require(await positions.location(bookID: book.id))
        #expect(kept.cfi == here.cfi)
    }

    @Test func aBookWhoseFileIsGoneIsDroppedOnLaunch() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let kept = try await shelve("no-cover.epub", in: library)
        let gone = try await shelve("long.epub", in: library, read: Date())
        // Its cover, place and last spread are all there, and its file isn't.
        try FileManager.default.createDirectory(at: library.coversDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: library.coverURL(for: gone))
        await positions.save(
            ReaderLocation(
                cfi: "epubcfi(/6/8!/4/2)", fraction: 0.2, chapterTitle: nil, chapterMinutesLeft: 1,
                isAtStart: false, isAtEnd: false, page: 2, pageCount: 10),
            bookID: gone.id)
        library.spreads.save(try spreadImage(), signature: "look", bookID: gone.id)
        await library.spreads.written()
        try FileManager.default.removeItem(at: library.fileURL(for: gone))

        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        let route = coordinator.prepareLaunch()
        #expect(route == .library)
        #expect(library.books.map(\.id) == [kept.id])
        await library.removed()
        await library.saved()
        #expect(!FileManager.default.fileExists(atPath: library.coverURL(for: gone).path))
        #expect(await positions.location(bookID: gone.id) == nil)
        #expect(library.spreads.image(bookID: gone.id, signature: "look") == nil)
        #expect(!FileManager.default.fileExists(atPath: library.spreads.imageURL(bookID: gone.id).path))
        // And it stays gone.
        #expect(LibraryStore(directory: folder, positions: positions).books.map(\.id) == [kept.id])
    }

    @Test func aFileReplacedByJunkGoesBackToTheLibrary() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("no-cover.epub", in: library, read: Date())
        try Data("not a book at all".utf8).write(to: library.fileURL(for: book))

        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        await coordinator.open(book)
        #expect(coordinator.isShowingLibrary)
        #expect(coordinator.drops.notice == [.unreadable])
        // It's still on the shelf: only a file that's gone takes a book off it.
        #expect(library.book(id: book.id) != nil)
    }
}

/// The reader telling the library where it is, and the app waiting for that to be written as it quits.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct ReadingWiringTests {
    private let here = ReaderLocation(
        cfi: "epubcfi(/6/8!/4/2)", fraction: 0.2, chapterTitle: "One", chapterMinutesLeft: 5,
        isAtStart: false, isAtEnd: false, page: 2, pageCount: 10)

    @Test func theFirstReadIsMarkedAtOnceAndTheRestAtMostOncePerInterval() {
        var marked: [(String, ReaderLocation)] = []
        let marker = ReadMarker(interval: .seconds(3600)) { marked.append(($0, $1)) }
        marker.read(id: "a", location: here)
        #expect(marked.map(\.0) == ["a"])
        var later = here
        later.chapterTitle = "Two"
        marker.read(id: "a", location: later)
        var latest = here
        latest.chapterTitle = "Three"
        marker.read(id: "a", location: latest)
        #expect(marked.count == 1)
        // Another book is marked at once, and the first book's last place isn't lost to it.
        marker.read(id: "b", location: here)
        #expect(marked.map(\.0) == ["a", "a", "b"])
        #expect(marked[1].1.chapterTitle == "Three")
        marker.read(id: "b", location: later)
        marker.flush()
        #expect(marked.map(\.0) == ["a", "a", "b", "b"])
        #expect(marked[3].1.chapterTitle == "Two")
        marker.flush()
        #expect(marked.count == 4)
    }

    @Test func openingABookMarksItReadAndQuittingWritesWhereItWasLeft() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        #expect(library.book(id: book.id)?.lastReadAt == nil)

        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        await coordinator.open(book)
        #expect(!coordinator.isShowingLibrary)
        let opened = try #require(library.book(id: book.id))
        #expect(opened.lastReadAt != nil)
        #expect(opened.chapterMinutesLeft != nil)

        let reader = coordinator.reader
        reader.perform(.goToEnd)
        await reader.settled()
        let end = try #require(reader.location)
        await coordinator.prepareToQuit()
        // What's on disk is what the next launch sees.
        let reloaded = LibraryStore(directory: folder, positions: positions)
        let saved = try #require(reloaded.book(id: book.id))
        #expect(saved.chapterTitle == end.chapterTitle)
        #expect(saved.chapterMinutesLeft == end.chapterMinutesLeft)
        #expect(await positions.location(bookID: book.id)?.cfi == end.cfi)
        let route = LaunchRoute.resolve(
            library: reloaded, positions: [book.id: try #require(await positions.location(bookID: book.id))],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) })
        #expect(route == .read(saved, cfi: end.cfi))
    }

    @Test func theLastSpreadIsKeptForItsLookOnly() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let spreads = LastSpreadCache(directory: folder)
        spreads.save(try spreadImage(), signature: "paper 1048x620@2", bookID: "a")
        await spreads.written()
        #expect(spreads.image(bookID: "a", signature: "paper 1048x620@2")?.width == 8)
        #expect(spreads.image(bookID: "a", signature: "night 1048x620@2") == nil)
        #expect(spreads.image(bookID: "b", signature: "paper 1048x620@2") == nil)
        await spreads.remove(bookID: "a")
        #expect(spreads.image(bookID: "a", signature: "paper 1048x620@2") == nil)
    }
}

/// Opening a book more than once, and taking the open book off the shelf.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct OpenBookTests {
    @Test func openingTheBookAlreadyOpeningOrOpenLoadsItOnce() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        coordinator.showLibrary()

        // A double click: the second arrives while the first is still opening.
        let first = Task { await coordinator.open(book) }
        await Task.yield()
        let second = Task { await coordinator.open(book) }
        await first.value
        await second.value
        #expect(coordinator.reader.loadsStarted == 1)
        #expect(!coordinator.isShowingLibrary)
        let view = try #require(coordinator.reader.book)

        // And once it's open, from the library again.
        coordinator.showLibrary()
        await coordinator.open(book)
        #expect(coordinator.reader.loadsStarted == 1)
        #expect(coordinator.reader.book === view)
        #expect(!coordinator.isShowingLibrary)
    }

    @Test func openingABookAnyWayClearsTheShelfSearch() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        coordinator.showLibrary()
        coordinator.search.open()
        coordinator.search.query = "nothing like it"

        // As ⌘O, the Dock and launching do, not by a click on the shelf.
        await coordinator.open(book)
        #expect(coordinator.search.query == "")
        #expect(!coordinator.search.isOpen)
    }

    @Test func puttingTheLibraryAwayTakesTheKeyboardFromIt() throws {
        let reader = ReaderWindowController(
            defaults: scratchDefaults(), positions: PositionStore(directory: try libraryFolder()), library: nil)
        defer { reader.window?.close() }
        let shelf = NSView()
        let field = NSTextField()
        shelf.addSubview(field)
        reader.setLibrary(shelf)
        reader.showLibrary(animated: false)
        let window = try #require(reader.window)
        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSView)?.isDescendant(of: shelf) == true)

        reader.showBook(animated: false)
        #expect((window.firstResponder as? NSView)?.isDescendant(of: shelf) != true)
    }

    @Test func removingTheOpenBookClosesIt() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        await coordinator.open(book)
        coordinator.reader.perform(.goToEnd)
        await coordinator.reader.settled()
        coordinator.showLibrary()

        library.remove(id: book.id)
        #expect(coordinator.reader.openBook == nil)
        #expect(coordinator.reader.book == nil)
        #expect(coordinator.reader.window?.title == "Readme")
        await library.removed()
        await coordinator.prepareToQuit()
        #expect(await positions.location(bookID: book.id) == nil)
        #expect(library.spreads.image(bookID: book.id, signature: "") == nil)
        #expect(!FileManager.default.fileExists(atPath: library.spreads.imageURL(bookID: book.id).path))
    }

    @Test func aBookThatWontOpenLeavesTheLibraryWhereItIs() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("no-cover.epub", in: library)
        try Data("not a book at all".utf8).write(to: library.fileURL(for: book))
        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        coordinator.showLibrary()
        var shown: [Bool] = []
        let previous = coordinator.reader.onShowingLibraryChange
        coordinator.reader.onShowingLibraryChange = { shown.append($0); previous?($0) }
        await coordinator.open(book)
        #expect(coordinator.isShowingLibrary)
        #expect(shown.isEmpty, "The library went \(shown)")
        #expect(coordinator.drops.notice == [.unreadable])
    }
}

/// The picture of the last spread, saved by a reading window, is the one the next launch shows.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct LastSpreadRoundTripTests {
    @Test func aSpreadSavedWhileReadingIsShownAtTheNextLaunchInTheSameLookOnly() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let book = try await shelve("long.epub", in: library)
        let defaults = scratchDefaults()
        var paper = ReaderSettings()
        paper.theme = .paper
        paper.save(defaults)
        let size = NSSize(width: 1048, height: 620)

        func window() -> ReaderWindowController {
            let reader = ReaderWindowController(defaults: defaults, positions: positions, library: library)
            reader.window?.setFrameAutosaveName("")
            reader.window?.setContentSize(size)
            return reader
        }

        let reading = window()
        reading.window?.orderFrontRegardless()
        await reading.open(book)
        await reading.settled()
        reading.turn(.forward)
        await reading.keepPlace()
        reading.turn(.forward)
        await reading.keepPlace()
        reading.window?.close()
        #expect(FileManager.default.fileExists(atPath: library.spreads.imageURL(bookID: book.id).path))

        // The next launch, in the same window and theme.
        let next = window()
        defer { next.window?.close() }
        #expect(next.showLastSpread(of: book))

        // A different size, or theme, shows nothing rather than the wrong picture.
        let smaller = window()
        defer { smaller.window?.close() }
        smaller.window?.setContentSize(NSSize(width: 900, height: 600))
        #expect(!smaller.showLastSpread(of: book))
        var night = paper
        night.theme = .night
        night.save(defaults)
        let dark = window()
        defer { dark.window?.close() }
        #expect(!dark.showLastSpread(of: book))
    }
}

/// A book taken off the shelf while it's waiting to open.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct RemovalDuringOpenTests {
    @Test func removingTheBookWaitingToOpenLeavesTheOpenBookAlone() async throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let positions = PositionStore(directory: folder.appendingPathComponent("Positions", isDirectory: true))
        let library = LibraryStore(directory: folder, positions: positions)
        let open = try await shelve("long.epub", in: library)
        let next = try await shelve("no-cover.epub", in: library)
        let coordinator = AppCoordinator(library: library, positions: positions, defaults: scratchDefaults())
        defer { coordinator.reader.window?.close() }
        coordinator.reader.window?.setFrameAutosaveName("")
        await coordinator.open(open)
        coordinator.showLibrary()
        let loads = coordinator.reader.loadsStarted

        let opening = Task { await coordinator.open(next) }
        await Task.yield()
        library.remove(id: next.id)
        await opening.value
        await library.removed()
        #expect(coordinator.reader.openBook?.id == open.id)
        #expect(coordinator.reader.loadsStarted == loads)
        #expect(await positions.location(bookID: next.id) == nil)
    }
}
