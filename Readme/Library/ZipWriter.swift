import Foundation

/// The zip format's CRC-32 (IEEE, reflected, polynomial 0xEDB88320).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Writes a zip whose entries are stored as they are, uncompressed, which is all a library bundle
/// needs: its books are zips already. There's no ZIP64, so a file that would pass `limit` bytes or
/// hold 65535 entries fails with `.tooLarge`. Any failure deletes what was written, so there's never
/// a broken file left behind.
final class ZipWriter {
    enum Failure: Error, Equatable {
        case tooLarge
        case unwritable
    }

    private struct Entry {
        var name: Data
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private let url: URL
    private let limit: UInt64
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var entries: [Entry] = []

    /// Creates the file, or empties the one that's there.
    init(url: URL, limit: UInt64 = 0xFFFF_FFFE) throws {
        self.url = url
        self.limit = limit
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw Failure.unwritable }
        self.handle = handle
    }

    func add(_ name: String, contentsOf file: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: file) } catch { throw fail(.unwritable) }
        try add(name, data: data)
    }

    func add(_ name: String, data: Data) throws {
        let nameData = Data(name.utf8)
        // This entry, and the directory record and end record that will follow it, must fit.
        let end = offset + 30 + UInt64(nameData.count) + UInt64(data.count)
        let directory = UInt64(entries.reduce(0) { $0 + 46 + $1.name.count }) + 46 + UInt64(nameData.count)
        guard entries.count + 1 < 0xFFFF, nameData.count <= 0xFFFF, end + directory + 22 <= limit else {
            throw fail(.tooLarge)
        }
        let entry = Entry(name: nameData, crc: CRC32.checksum(data), size: UInt32(data.count), offset: UInt32(offset))
        var header = Data()
        header.append32(0x0403_4B50)
        header.append16(20)
        header.append16(0x0800)
        header.append16(0)
        header.append16(0)
        header.append16(0)
        header.append32(entry.crc)
        header.append32(entry.size)
        header.append32(entry.size)
        header.append16(UInt16(nameData.count))
        header.append16(0)
        header.append(nameData)
        try write(header)
        try write(data)
        entries.append(entry)
    }

    /// Writes the directory, closes the file, and leaves it complete.
    func finish() throws {
        let start = offset
        var directory = Data()
        for entry in entries {
            directory.append32(0x0201_4B50)
            directory.append16(20)
            directory.append16(20)
            directory.append16(0x0800)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append32(entry.crc)
            directory.append32(entry.size)
            directory.append32(entry.size)
            directory.append16(UInt16(entry.name.count))
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append16(0)
            directory.append32(0)
            directory.append32(entry.offset)
            directory.append(entry.name)
        }
        var end = Data()
        end.append32(0x0605_4B50)
        end.append16(0)
        end.append16(0)
        end.append16(UInt16(entries.count))
        end.append16(UInt16(entries.count))
        end.append32(UInt32(directory.count))
        end.append32(UInt32(start))
        end.append16(0)
        try write(directory)
        try write(end)
        do { try handle?.close() } catch { throw fail(.unwritable) }
        handle = nil
    }

    private func write(_ data: Data) throws {
        guard let handle else { throw Failure.unwritable }
        do { try handle.write(contentsOf: data) } catch { throw fail(.unwritable) }
        offset += UInt64(data.count)
    }

    /// Closes and deletes the file, and hands back `failure` to throw.
    private func fail(_ failure: Failure) -> Failure {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
        return failure
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append32(_ value: UInt32) {
        append16(UInt16(value & 0xFFFF))
        append16(UInt16(value >> 16))
    }
}
