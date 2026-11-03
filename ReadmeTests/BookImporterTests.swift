import AppKit
import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

/// A PNG of the given size, drawn by hand so the test needs no file.
private func pngData(width: Int, height: Int) throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func pixelSize(of data: Data) throws -> (Int, Int) {
    let bitmap = try #require(NSBitmapImageRep(data: data))
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct BookImporterTests {
    let folder: URL
    let store: LibraryStore
    let importer: BookImporter

    init() throws {
        folder = try libraryFolder()
        store = LibraryStore(directory: folder)
        importer = BookImporter(store: store)
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    @Test func importsAndCopies() async throws {
        defer { clean() }
        let original = try fixture("long.epub")
        let before = try Data(contentsOf: original)
        let book = try await importer.importBook(from: original)
        #expect(store.books == [book])
        #expect(book.id == (try await BookID.of(original)))
        #expect(try Data(contentsOf: store.fileURL(for: book)) == before)
        #expect(store.fileURL(for: book).path.hasPrefix(folder.path))
        #expect(try Data(contentsOf: original) == before)
        #expect(book.hasCover)
        let cover = try Data(contentsOf: store.coverURL(for: book))
        #expect(NSBitmapImageRep(data: cover) != nil)
    }

    @Test func readsMetadata() async throws {
        defer { clean() }
        let book = try await importer.importBook(from: fixture("long.epub"))
        #expect(book.title == "Long Fixture Book")
        #expect(book.author == "Fixture Author")
    }

    @Test func sameBookTwiceIsOneBook() async throws {
        defer { clean() }
        let first = try await importer.importBook(from: fixture("long.epub"))
        let second = try await importer.importBook(from: fixture("long.epub"))
        #expect(first == second)
        #expect(store.books.count == 1)
        let files = try FileManager.default.contentsOfDirectory(
            at: store.fileURL(for: first).deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }

    @Test func rejectsDRM() async throws {
        defer { clean() }
        await #expect(throws: ImportError.copyProtected) {
            try await importer.importBook(from: fixture("drm.epub"))
        }
        #expect(store.books.isEmpty)
        #expect(try leftovers().isEmpty)
    }

    @Test func fontObfuscationAloneIsNotDRM() async throws {
        defer { clean() }
        let book = try await importer.importBook(from: fixture("obfuscated.epub"))
        #expect(book.title == "Obfuscated Fonts Book")
    }

    @Test func rejectsJunk() async throws {
        defer { clean() }
        await #expect(throws: ImportError.notAnEPUB) {
            try await importer.importBook(from: fixture("not-an-epub.epub"))
        }
        #expect(store.books.isEmpty)
        #expect(try leftovers().isEmpty)
    }

    @Test func aZipThatIsNotAnEPUBIsJunk() async throws {
        defer { clean() }
        await #expect(throws: ImportError.notAnEPUB) {
            try await importer.importBook(from: fixture("plain-zip.epub"))
        }
        #expect(store.books.isEmpty)
    }

    @Test func missingFileIsUnreadable() async throws {
        defer { clean() }
        await #expect(throws: ImportError.unreadable) {
            try await importer.importBook(from: folder.appendingPathComponent("nothing.epub"))
        }
    }

    @Test func brokenButOpenableImports() async throws {
        defer { clean() }
        let broken = try await importer.importBook(from: fixture("broken-chapter.epub"))
        let bare = try await importer.importBook(from: fixture("no-cover.epub"))
        #expect(store.books.count == 2)
        #expect(bare.hasCover == false)
        #expect(!FileManager.default.fileExists(atPath: store.coverURL(for: bare).path))
        #expect(!broken.title.isEmpty)
    }

    @Test func dropOfManyKeepsGoing() async throws {
        defer { clean() }
        let results = await importer.importAll([
            try fixture("long.epub"), try fixture("not-an-epub.epub"), try fixture("no-cover.epub"),
        ])
        #expect(results.count == 3)
        #expect(results.compactMap { try? $0.get() }.count == 2)
        #expect(results[1] == .failure(.notAnEPUB))
        #expect(store.books.count == 2)
    }

    @Test func aHugeCoverIsScaledDown() throws {
        let big = try pngData(width: 3000, height: 2000)
        let scaled = try #require(CoverImage.png(from: big))
        let (width, height) = try pixelSize(of: scaled)
        #expect(max(width, height) == CoverImage.maxSide)
        #expect(width > height)
        let small = try pngData(width: 300, height: 400)
        let (smallWidth, smallHeight) = try pixelSize(of: try #require(CoverImage.png(from: small)))
        #expect((smallWidth, smallHeight) == (300, 400))
        #expect(CoverImage.png(from: Data("not an image".utf8)) == nil)
    }

    /// Files the importer left in the library's folders, which a failed import mustn't.
    private func leftovers() throws -> [URL] {
        let fileManager = FileManager.default
        return ["Books", "Covers"].flatMap { name -> [URL] in
            let directory = folder.appendingPathComponent(name)
            return (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
    }
}
