import Foundation
import WebKit

/// Serves `readme-book://app/…`: the bundled `Web` folder, plus the current book at a path that
/// changes with each open. Files are read away from the main thread and streamed in chunks.
@MainActor
final class BookScheme: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "readme-book"
    nonisolated static let readerURL = URL(string: "readme-book://app/reader.html")!
    /// foliate's README requires scripts to be blocked by CSP: WebKit needs `allow-scripts` on its
    /// iframes, and they inherit this policy through their `blob:` URLs.
    nonisolated static let contentSecurityPolicy = "default-src 'self' blob: readme-book:; script-src 'self'; connect-src 'self' blob: readme-book:; img-src * blob: data: readme-book:; style-src * 'unsafe-inline'; font-src * blob: data: readme-book:"

    private static let host = "app"
    private static let bookFolder = "/book/"
    private nonisolated static let chunkSize = 256 * 1024

    private let webRoot: URL
    private var bookPath: String?
    private var bookFile: URL?
    private var running: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private var readers: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(webRoot: URL) {
        self.webRoot = webRoot
    }

    /// Makes `file` available to the page and returns the URL to fetch it from.
    func serve(book file: URL) -> URL {
        let path = Self.bookFolder + UUID().uuidString
        bookPath = path
        bookFile = file
        return URL(string: "\(Self.scheme)://\(Self.host)\(path)")!
    }

    /// The file under `root` for a request path, or nil if the path is empty or leaves `root`.
    nonisolated static func resourceURL(forPath path: String, in root: URL) -> URL? {
        let relative = path.drop { $0 == "/" }
        guard !relative.isEmpty else { return nil }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = root.appendingPathComponent(String(relative))
            .standardizedFileURL.resolvingSymlinksInPath()
        return candidate.path.hasPrefix(rootPath + "/") ? candidate : nil
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running[id] = task
        let url = task.request.url
        let file = fileToServe(for: url)
        let isReader = url == Self.readerURL
        let isBook = file != nil && file == bookFile
        readers[id] = Task.detached { [weak self] in
            await Self.stream(file, id: id, isReader: isReader, isBook: isBook, to: self)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running[id] = nil
        readers.removeValue(forKey: id)?.cancel()
    }

    private func fileToServe(for url: URL?) -> URL? {
        guard let url, url.scheme == Self.scheme, url.host == Self.host else { return nil }
        if url.path.hasPrefix(Self.bookFolder) {
            return url.path == bookPath ? bookFile : nil
        }
        return Self.resourceURL(forPath: url.path, in: webRoot)
    }

    private nonisolated static func stream(
        _ file: URL?, id: ObjectIdentifier, isReader: Bool, isBook: Bool, to scheme: BookScheme?
    ) async {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else {
            await scheme?.respond(id, status: 404, length: 0, mimeType: "text/plain", isReader: false)
            await scheme?.finish(id, error: nil)
            return
        }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        do {
            try handle.seek(toOffset: 0)
            let mimeType = isBook ? "application/epub+zip" : mimeType(for: file)
            await scheme?.respond(id, status: 200, length: length, mimeType: mimeType, isReader: isReader)
            while !Task.isCancelled, let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                await scheme?.deliver(id, chunk)
            }
            await scheme?.finish(id, error: nil)
        } catch {
            await scheme?.finish(id, error: error)
        }
    }

    // WebKit throws an exception if a task it has stopped is sent anything, so each of these
    // checks that the task is still running.

    private func respond(_ id: ObjectIdentifier, status: Int, length: UInt64, mimeType: String, isReader: Bool) {
        guard let task = running[id], let url = task.request.url else { return }
        var headers = ["Content-Type": mimeType, "Content-Length": String(length), "Cache-Control": "no-store"]
        if isReader { headers["Content-Security-Policy"] = Self.contentSecurityPolicy }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
    }

    private func deliver(_ id: ObjectIdentifier, _ data: Data) {
        running[id]?.didReceive(data)
    }

    private func finish(_ id: ObjectIdentifier, error: (any Error)?) {
        guard let task = running.removeValue(forKey: id) else { return }
        readers[id] = nil
        if let error { task.didFailWithError(error) } else { task.didFinish() }
    }

    private nonisolated static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: "application/octet-stream"
        }
    }
}
