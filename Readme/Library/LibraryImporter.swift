import Foundation
import OSLog

/// A bundle opened and sorted: the books new to this library, and those already in it, each in the
/// bundle's order.
struct PreparedImport: Sendable {
    let bundle: OpenedBundle
    let newIDs: [String]
    let existingIDs: [String]
}

/// What to do with the books that are here already.
enum ImportChoice: Sendable {
    /// Leave them exactly as they are.
    case keepMine
    /// Add the highlights not here yet, keep the further place, and keep this Mac's marker if it has one.
    case combine
}

/// How an import went.
struct ImportSummary: Equatable, Sendable {
    var added = 0
    var combined = 0
    var kept = 0
    var failed = 0

    var line: String {
        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? "added 1 book" : "added \(added) books") }
        if combined > 0 { parts.append("combined \(combined)") }
        if kept > 0 { parts.append("left \(kept) as they were") }
        if failed > 0 { parts.append("\(failed) couldn't be read") }
        guard !parts.isEmpty else { return "Nothing to import" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Brings books in from a bundle. A book already in the library is never replaced: at most, with
/// `.combine`, what the bundle knows about it is added to what's here.
@MainActor
struct LibraryImporter {
    let store: LibraryStore
    let importer: BookImporter
    private nonisolated static let log = Logger(subsystem: "com.rajanchavda.Readme", category: "LibraryImporter")

    init(store: LibraryStore, importer: BookImporter) {
        self.store = store
        self.importer = importer
    }

    /// Opens and checks the bundle, and sorts its books.
    func prepare(_ url: URL) async throws(BundleError) -> PreparedImport {
        let result = await Task.detached { () -> Result<OpenedBundle, BundleError> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do throws(BundleError) { return .success(try LibraryBundle.open(url)) } catch { return .failure(error) }
        }.value
        let bundle = try result.get()
        let ids = bundle.manifest.bookIDs
        return PreparedImport(
            bundle: bundle,
            newIDs: ids.filter { store.book(id: $0) == nil },
            existingIDs: ids.filter { store.book(id: $0) != nil })
    }

    func run(_ prepared: PreparedImport, choice: ImportChoice) async -> ImportSummary {
        let url = prepared.bundle.url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var summary = ImportSummary()
        for id in prepared.bundle.manifest.bookIDs {
            // Sorted when prepared, but another import may have added it since.
            if store.book(id: id) != nil {
                switch choice {
                case .keepMine:
                    summary.kept += 1
                case .combine:
                    if await combine(id, from: prepared.bundle) { summary.combined += 1 } else { summary.failed += 1 }
                }
            } else if await add(id, from: prepared.bundle) {
                summary.added += 1
            } else {
                summary.failed += 1
            }
        }
        return summary
    }

    /// A book new here: its file through the usual import, then everything the bundle knows about it.
    private func add(_ id: String, from bundle: OpenedBundle) async -> Bool {
        let staged = store.booksDirectory.appendingPathComponent(".bundle-\(UUID().uuidString).epub", isDirectory: false)
        let books = store.booksDirectory
        defer { try? FileManager.default.removeItem(at: staged) }
        let extracted = await Task.detached { () -> BundleContents? in
            do throws(BundleError) {
                try? FileManager.default.createDirectory(at: books, withIntermediateDirectories: true)
                let contents = try bundle.contents(of: id)
                try bundle.extractEPUB(of: id, to: staged)
                return contents
            } catch {
                return nil
            }
        }.value
        guard let contents = extracted, (try? await BookID.of(staged)) == id else {
            Self.log.error("A book in the bundle couldn't be read, or isn't the book it says it is")
            return false
        }
        do {
            _ = try await importer.importBook(from: staged)
        } catch {
            return false
        }
        store.applyImported(id: id, addedAt: contents.info.addedAt, lastReadAt: contents.info.lastReadAt, location: contents.position)
        await store.highlights.merge(contents.highlights, bookID: id)
        if let marker = contents.marker { await store.markers.setIfNone(marker, bookID: id) }
        if let position = contents.position, ImportMerge.isFurther(position, than: await store.positions.location(bookID: id)) {
            await store.positions.save(position, bookID: id)
        }
        return true
    }

    /// A book already here: the bundle's highlights it doesn't have, its marker if there's none here,
    /// and its place if that's further along.
    private func combine(_ id: String, from bundle: OpenedBundle) async -> Bool {
        let read = await Task.detached { () -> BundleContents? in try? bundle.contents(of: id) }.value
        guard let contents = read else { return false }
        await store.highlights.merge(contents.highlights, bookID: id)
        if let marker = contents.marker { await store.markers.setIfNone(marker, bookID: id) }
        var further: ReaderLocation?
        if let position = contents.position, ImportMerge.isFurther(position, than: await store.positions.location(bookID: id)) {
            await store.positions.save(position, bookID: id)
            further = position
        }
        store.applyImported(id: id, addedAt: nil, lastReadAt: contents.info.lastReadAt, location: further)
        // The picture of where it was left may no longer be where it opens.
        if further != nil { await store.spreads.remove(bookID: id) }
        return true
    }
}
