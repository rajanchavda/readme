import Foundation

/// How an export went.
struct ExportSummary: Equatable, Sendable {
    var exported: Int
    var missing: Int

    var line: String {
        var text = exported == 1 ? "Exported 1 book" : "Exported \(exported) books"
        if missing == 1 {
            text += ", 1 was missing and left out"
        } else if missing > 1 {
            text += ", \(missing) were missing and left out"
        }
        return text
    }
}

/// Puts books from the library, with their highlights, marker and place, into one bundle file.
@MainActor
struct LibraryExporter {
    let store: LibraryStore

    /// Books whose copy has gone are left out and counted. The caller holds `url`'s security scope.
    func export(_ books: [Book], to url: URL, now: Date = Date()) async throws(BundleError) -> ExportSummary {
        var items: [BundleItem] = []
        var missing = 0
        for book in books {
            let file = store.fileURL(for: book)
            guard FileManager.default.fileExists(atPath: file.path) else {
                missing += 1
                continue
            }
            items.append(BundleItem(
                id: book.id,
                info: BundledBook(title: book.title, author: book.author, addedAt: book.addedAt, lastReadAt: book.lastReadAt),
                epub: file,
                highlights: await store.highlights.highlights(bookID: book.id),
                marker: await store.markers.marker(bookID: book.id),
                position: await store.positions.location(bookID: book.id)))
        }
        guard !items.isEmpty else { throw .unwritable }
        let ready = items
        let result = await Task.detached { () -> BundleError? in
            do throws(BundleError) {
                try LibraryBundle.write(ready, to: url, exportedAt: now)
                return nil
            } catch {
                return error
            }
        }.value
        if let result { throw result }
        return ExportSummary(exported: items.count, missing: missing)
    }
}
