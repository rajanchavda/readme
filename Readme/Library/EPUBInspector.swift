import Compression
import Foundation

/// Looks inside an EPUB's zip before any web view does, to tell a book from junk and a book that can
/// be read from one that's copy-protected.
enum EPUBInspector {
    /// Font obfuscation, which a reading system undoes with the book's own identifier. Everything
    /// else in `encryption.xml` is real encryption, and needs a licence the app doesn't have.
    static let obfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// Throws `.notAnEPUB` for a file that isn't a zip with a mimetype or a container.xml, and
    /// `.copyProtected` for one that encrypts anything but fonts' obfuscation. A file that can't be
    /// read at all is `.unreadable`.
    static func check(_ url: URL) throws(ImportError) {
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw .unreadable }
        guard let archive = ZipArchive(url) else { throw .notAnEPUB }
        guard archive.contains("mimetype") || archive.contains("META-INF/container.xml") else {
            throw .notAnEPUB
        }
        if let encryption = archive.data(for: "META-INF/encryption.xml"),
           !encryptionMethods(in: encryption).isSubset(of: obfuscationAlgorithms) {
            throw .copyProtected
        }
    }

    /// The algorithm of each EncryptionMethod. A file that doesn't parse names none, so the book gets
    /// its chance to open, and is turned away then if it can't.
    static func encryptionMethods(in data: Data) -> Set<String> {
        let collector = MethodCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.parse()
        return collector.algorithms
    }

    private final class MethodCollector: NSObject, XMLParserDelegate {
        var algorithms: Set<String> = []

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
            qualifiedName: String?, attributes: [String: String]
        ) {
            if name == "EncryptionMethod" { algorithms.insert(attributes["Algorithm"] ?? "") }
        }
    }
}

/// The entries of a zip file, read through its central directory, so only the entries asked for are
/// read. Handles stored and deflated entries, which are all an EPUB has. A zip that needs ZIP64 isn't
/// read, and counts as not being one.
struct ZipArchive {
    private struct Entry {
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var headerOffset: Int
    }

    private let url: URL
    private let entries: [String: Entry]

    init?(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return nil }
        // The end record is 22 bytes plus a comment of up to 65535.
        let tail = min(length, 22 + 65535)
        guard (try? handle.seek(toOffset: length - tail)) != nil,
              let end = try? handle.read(upToCount: Int(tail)),
              let recordStart = end.lastIndex(ofSignature: 0x0605_4b50)
        else { return nil }
        let record = end.dropFirst(recordStart - end.startIndex)
        guard record.count >= 22 else { return nil }
        let count = Int(record.uint16(at: 10))
        let directorySize = Int(record.uint32(at: 12))
        let directoryOffset = Int(record.uint32(at: 16))
        guard count != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF,
              UInt64(directoryOffset + directorySize) <= length,
              (try? handle.seek(toOffset: UInt64(directoryOffset))) != nil,
              let directory = try? handle.read(upToCount: directorySize),
              directory.count == directorySize
        else { return nil }

        var entries: [String: Entry] = [:]
        var position = 0
        for _ in 0..<count {
            guard position + 46 <= directory.count, directory.uint32(at: position) == 0x0201_4b50 else { return nil }
            let nameLength = Int(directory.uint16(at: position + 28))
            let extraLength = Int(directory.uint16(at: position + 30))
            let commentLength = Int(directory.uint16(at: position + 32))
            let nameStart = position + 46
            guard nameStart + nameLength <= directory.count else { return nil }
            let name = String(decoding: directory.subdata(in: directory.startIndex + nameStart..<directory.startIndex + nameStart + nameLength), as: UTF8.self)
            entries[name] = Entry(
                method: directory.uint16(at: position + 10),
                compressedSize: Int(directory.uint32(at: position + 20)),
                size: Int(directory.uint32(at: position + 24)),
                headerOffset: Int(directory.uint32(at: position + 42)))
            position = nameStart + nameLength + extraLength + commentLength
        }
        self.url = url
        self.entries = entries
    }

    func contains(_ name: String) -> Bool {
        entries[name] != nil
    }

    /// The entry's bytes, or nil if there's no such entry or it can't be inflated.
    func data(for name: String) -> Data? {
        guard let entry = entries[name], let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(entry.headerOffset))) != nil,
              let header = try? handle.read(upToCount: 30), header.count == 30,
              header.uint32(at: 0) == 0x0403_4b50
        else { return nil }
        let skip = Int(header.uint16(at: 26)) + Int(header.uint16(at: 28))
        guard (try? handle.seek(toOffset: UInt64(entry.headerOffset + 30 + skip))) != nil,
              let packed = try? handle.read(upToCount: entry.compressedSize), packed.count == entry.compressedSize
        else { return nil }
        switch entry.method {
        case 0:
            return packed
        case 8:
            // Compression's zlib is raw deflate, which is what a zip holds.
            var output = Data(count: max(entry.size, 1))
            let written = output.withUnsafeMutableBytes { out in
                packed.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                        input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            return written == entry.size ? output.prefix(written) : nil
        default:
            return nil
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(uint16(at: offset)) | UInt32(uint16(at: offset + 2)) << 16
    }

    /// The last place the four bytes of `signature`, little-endian, begin.
    func lastIndex(ofSignature signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: 0, by: -1) where uint32(at: offset) == signature {
            return startIndex + offset
        }
        return nil
    }
}
