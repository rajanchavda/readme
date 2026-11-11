import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

/// A file from the test bundle's fixtures, for the export and import tests.
func exportFixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

@Suite struct ZipWriterTests {
    let folder: URL
    let url: URL

    init() throws {
        folder = try libraryFolder()
        url = folder.appendingPathComponent("out.zip")
    }

    private func clean() { try? FileManager.default.removeItem(at: folder) }

    @Test func crcOfTheStandardCheckString() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }

    @Test func roundTripsThroughZipArchive() throws {
        defer { clean() }
        let book = try exportFixture("long.epub")
        let writer = try ZipWriter(url: url)
        try writer.add("a.json", data: Data(#"{"k":1}"#.utf8))
        try writer.add("books/x/book.epub", contentsOf: book)
        try writer.finish()
        let archive = try #require(ZipArchive(url))
        #expect(Set(archive.names) == ["a.json", "books/x/book.epub"])
        #expect(archive.data(for: "a.json", limit: 1 << 20) == Data(#"{"k":1}"#.utf8))
        #expect(archive.data(for: "books/x/book.epub", limit: 1 << 30) == (try Data(contentsOf: book)))
    }

    @Test func overwritesAnExistingFile() throws {
        defer { clean() }
        try Data(repeating: 0xFF, count: 1 << 20).write(to: url)
        let writer = try ZipWriter(url: url)
        try writer.add("a.json", data: Data("{}".utf8))
        try writer.finish()
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 1024)
        #expect(ZipArchive(url) != nil)
    }

    @Test func tooLargeFailsAndLeavesNoFile() throws {
        defer { clean() }
        let writer = try ZipWriter(url: url, limit: 100)
        #expect(throws: ZipWriter.Failure.tooLarge) { try writer.add("big", data: Data(count: 200)) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
