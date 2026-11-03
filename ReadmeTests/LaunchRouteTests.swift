import Foundation
import Testing
@testable import Readme

private func book(_ id: String, added: Double, read: Double? = nil) -> Book {
    Book(
        id: id, title: id, author: nil, fileName: "\(id).epub", hasCover: false,
        addedAt: Date(timeIntervalSince1970: added),
        lastReadAt: read.map { Date(timeIntervalSince1970: $0) },
        chapterTitle: nil, chapterMinutesLeft: nil)
}

private func place(_ cfi: String) -> ReaderLocation {
    ReaderLocation(
        cfi: cfi, fraction: 0.3, chapterTitle: "Chapter 3", chapterMinutesLeft: 12, isAtStart: false,
        isAtEnd: false, page: 30, pageCount: 100)
}

/// Where the app opens: straight into the book last read, or the library if there isn't one to go to.
@MainActor
@Suite struct LaunchRouteTests {
    @Test func noBooksShowsTheLibrary() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        #expect(LaunchRoute.resolve(library: library, positions: [:], fileExists: { _ in true }) == .library)
    }

    @Test func booksNeverOpenedShowTheLibrary() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("a", added: 1))
        library.add(book("b", added: 2))
        #expect(LaunchRoute.resolve(library: library, positions: [:], fileExists: { _ in true }) == .library)
    }

    @Test func theBookLastReadOpensAtItsPlace() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("old", added: 1, read: 10))
        library.add(book("last", added: 2, read: 20))
        library.add(book("new", added: 30))
        let positions = ["old": place("epubcfi(/6/4!/4/2)"), "last": place("epubcfi(/6/8!/4/2)")]
        let route = LaunchRoute.resolve(library: library, positions: positions, fileExists: { _ in true })
        #expect(route == .read(try #require(library.book(id: "last")), cfi: "epubcfi(/6/8!/4/2)"))
    }

    /// Read, but its place was never kept, so it opens at the start.
    @Test func theBookLastReadWithNoPlaceOpensAtItsStart() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("last", added: 2, read: 20))
        let route = LaunchRoute.resolve(library: library, positions: [:], fileExists: { _ in true })
        #expect(route == .read(try #require(library.book(id: "last")), cfi: nil))
    }

    @Test func theBookLastReadWithItsFileGoneShowsTheLibrary() throws {
        let folder = try libraryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(directory: folder)
        library.add(book("last", added: 2, read: 20))
        let positions = ["last": place("epubcfi(/6/8!/4/2)")]
        let gone = library.fileURL(for: try #require(library.book(id: "last")))
        let route = LaunchRoute.resolve(library: library, positions: positions, fileExists: { $0 != gone })
        #expect(route == .library)
    }
}
