import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Readme

@Suite struct ShelfLayoutTests {
    @Test func twelveBooksAtNineEightyAreSixAndSix() {
        let rows = ShelfLayout.rows(Array(0..<12), width: 980)
        #expect(rows.map(\.count) == [6, 6])
        #expect(rows.flatMap { $0 } == Array(0..<12))
    }

    @Test func sevenBooksAreSixAndOne() {
        #expect(ShelfLayout.rows(Array(0..<7), width: 980).map(\.count) == [6, 1])
    }

    @Test func noBooksMakeNoRows() {
        #expect(ShelfLayout.rows([Int](), width: 980).isEmpty)
    }

    @Test func aNarrowWindowStillHoldsOne() {
        #expect(ShelfLayout.rows(Array(0..<3), width: 400).allSatisfy { $0.count >= 1 })
        #expect(ShelfLayout.rows(Array(0..<3), width: 50).map(\.count) == [1, 1, 1])
        #expect(ShelfLayout.rows(Array(0..<3), width: 0).map(\.count) == [1, 1, 1])
    }

    @Test func aWiderWindowHoldsMore() {
        #expect(ShelfLayout.rows(Array(0..<20), width: 1400).first?.count == 9)
    }

    @Test func atLeastOneEmptyShelfStaysVisible() {
        for height in [0, 100, 300, 500, 700, 900, 1400] as [CGFloat] {
            #expect(ShelfLayout.emptyRowCount(height: height) >= 1, "\(height)")
        }
        #expect(ShelfLayout.emptyRowCount(height: 1400) > ShelfLayout.emptyRowCount(height: 600))
    }
}

@MainActor
@Suite struct ShelfTextTests {
    private func book(chapter: String?, minutes: Double?) -> Book {
        Book(id: "a", title: "T", author: nil, fileName: "a.epub", hasCover: false, addedAt: .now,
             lastReadAt: nil, chapterTitle: chapter, chapterMinutesLeft: minutes)
    }

    @Test func progressLineHasWhatTheBookHas() {
        #expect(CurrentBookShelf.progressLine(for: book(chapter: "Chapter 1, Loomings", minutes: 23)) == "Chapter 1, Loomings · 23 min left")
        #expect(CurrentBookShelf.progressLine(for: book(chapter: "Loomings", minutes: nil)) == "Loomings")
        #expect(CurrentBookShelf.progressLine(for: book(chapter: nil, minutes: 4.2)) == "5 min left")
        #expect(CurrentBookShelf.progressLine(for: book(chapter: nil, minutes: nil)) == nil)
        #expect(CurrentBookShelf.progressLine(for: book(chapter: "", minutes: nil)) == nil)
    }

    @Test func longTimesAreInHours() {
        #expect(CurrentBookShelf.timeLeft(0) == "1 min left")
        #expect(CurrentBookShelf.timeLeft(65) == "1 hr 5 min left")
        #expect(CurrentBookShelf.timeLeft(120) == "2 hr left")
    }

    @Test func oneMessagePerKindOfFailure() {
        let lines = ShelfDrops.messages(for: [.notAnEPUB, .copyProtected, .notAnEPUB, .notAnEPUB])
        #expect(lines == ["This file isn't an EPUB book.", "This book is copy-protected, so it can't be opened here."])
        #expect(ShelfDrops.message(for: .unreadable) == "This book couldn't be read.")
    }
}

private func someBook(_ n: Int = 0) -> Book {
    Book(id: "id\(n)", title: "T", author: nil, fileName: "\(n).epub", hasCover: false, addedAt: .now,
         lastReadAt: nil, chapterTitle: nil, chapterMinutesLeft: nil)
}

@MainActor
@Suite(.serialized) struct ShelfDropsTests {
    private func drops(
        _ results: @escaping @Sendable ([URL]) -> [Result<Book, ImportError>], notice: Duration = .seconds(10),
        progress: Duration = .seconds(10)
    ) -> ShelfDrops {
        ShelfDrops(noticeDuration: notice, progressDelay: progress, importAll: { results($0) })
    }

    private let file = URL(fileURLWithPath: "/tmp/a.epub")

    @Test func failureKindsMergeAcrossDrops() async {
        let first = drops { _ in [.failure(.notAnEPUB), .failure(.notAnEPUB)] }
        await first.add([file, file])
        #expect(first.lines == ["This file isn't an EPUB book."])

        var next: [Result<Book, ImportError>] = []
        let merged = ShelfDrops(importAll: { _ in next })
        next = [.failure(.notAnEPUB)]
        await merged.add([file])
        next = [.failure(.copyProtected), .failure(.notAnEPUB)]
        await merged.add([file, file])
        #expect(merged.notice == [.notAnEPUB, .copyProtected])
    }

    @Test func aBookAlreadyThereIsNotAnError() async {
        let d = drops { _ in [.success(someBook())] }
        await d.add([file])
        #expect(d.lines.isEmpty)
        #expect(d.adding == 0)
    }

    @Test func noticeFadesByItself() async throws {
        let d = drops({ _ in [.failure(.unreadable)] }, notice: .milliseconds(150))
        await d.add([file])
        #expect(d.lines == ["This book couldn't be read."])
        try await Task.sleep(for: .milliseconds(600))
        #expect(d.lines.isEmpty)
    }

    @Test func anotherFailureRestartsTheFade() async throws {
        let d = drops({ _ in [.failure(.unreadable)] }, notice: .milliseconds(500))
        await d.add([file])
        try await Task.sleep(for: .milliseconds(300))
        await d.add([file])
        // 600 ms after the first, which alone would have faded it, and 300 after the second.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!d.lines.isEmpty)
        try await Task.sleep(for: .milliseconds(700))
        #expect(d.lines.isEmpty)
    }

    @Test func aSlowImportSaysBooksAreBeingAdded() async throws {
        let d = ShelfDrops(noticeDuration: .seconds(10), progressDelay: .milliseconds(50), importAll: { files in
            try? await Task.sleep(for: .milliseconds(400))
            return files.map { _ in .success(someBook()) }
        })
        let running = Task { _ = await d.add([file, file, file]) }
        try await Task.sleep(for: .milliseconds(250))
        #expect(d.adding == 3)
        #expect(ShelfDrops.progressLine(3) == "Adding 3 books…")
        await running.value
        #expect(d.adding == 0)
    }

    @Test func aQuickImportSaysNothing() async {
        let d = drops { files in files.map { _ in .success(someBook()) } }
        await d.add([file])
        #expect(d.adding == 0)
    }
}

@MainActor
@Suite(.serialized) struct LibraryViewRenderTests {
    private func book(_ n: Int, title: String, author: String?, cover: Bool = false, read: Bool = false) -> Book {
        Book(
            id: String(format: "%064x", n * 7919 + 13), title: title, author: author, fileName: "\(n).epub",
            hasCover: cover, addedAt: Date(timeIntervalSince1970: Double(1000 + n)),
            lastReadAt: read ? Date(timeIntervalSince1970: 5000) : nil,
            chapterTitle: read ? "Chapter 1, Loomings" : nil, chapterMinutesLeft: read ? 23 : nil)
    }

    private func paint(_ color: NSColor, to url: URL) throws {
        let image = NSImage(size: NSSize(width: 400, height: 600), flipped: false) { rect in
            color.setFill(); rect.fill()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSRect(x: 40, y: 60, width: 320, height: 12).fill()
            NSRect(x: 40, y: 90, width: 200, height: 12).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private func snapshot(_ view: some View, size: CGSize) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Always renders the full library and checks the rail runs to the window's right edge. With
    /// `SHELF_RENDERS` set (`TEST_RUNNER_SHELF_RENDERS=1 scripts/test.sh`) it also saves renders for looking at.
    @Test func railReachesTheWindowEdgeAndRendersAreSaved() async throws {
        let dump = ProcessInfo.processInfo.environment["SHELF_RENDERS"] != nil
        BundledFonts.register()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("task14-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let titles: [(String, String?)] = [
            ("Moby-Dick", "Herman Melville"), ("Pride and Prejudice", "Jane Austen"), ("Frankenstein", "Mary Shelley"),
            ("The Odyssey", "Homer"), ("Middlemarch", "George Eliot"), ("Dracula", "Bram Stoker"),
            ("Walden", "Henry David Thoreau"), ("Jane Eyre", "Charlotte Brontë"), ("Great Expectations", "Charles Dickens"),
            ("Anna Karenina", "Leo Tolstoy"), ("The Time Machine", "H. G. Wells"), ("Little Women", "Louisa May Alcott"),
        ]
        let colors: [NSColor] = [.systemTeal, .systemBrown, .systemIndigo, .systemOrange]

        func library(count: Int) async throws -> LibraryStore {
            let store = LibraryStore(directory: try libraryFolder())
            try FileManager.default.createDirectory(at: store.coversDirectory, withIntermediateDirectories: true)
            for i in 0..<count {
                let real = i % 3 == 0
                let b = book(i, title: titles[i].0, author: titles[i].1, cover: real, read: i == 0)
                if real { try paint(colors[(i / 3) % colors.count], to: store.coverURL(for: b)) }
                store.add(b)
                if real { _ = await CoverImages.load(store.coverURL(for: b), width: i == 0 ? 150 : 112) }
            }
            return store
        }
        func importer(_ store: LibraryStore) -> BookImporter { BookImporter(store: store) }

        let size = CGSize(width: 980, height: 800)
        let twelve = try await library(count: 12)
        let check = try #require(snapshot(LibraryView(library: twelve, importer: importer(twelve), onOpen: { _ in }), size: size))
        #expect(check.pixelsWide == 1960)
        // The top shelf's rail is at 262...276 points down; the last pixel column is wood, not background.
        let edge = try #require(check.colorAt(x: 1958, y: 538)?.usingColorSpace(.deviceRGB))
        #expect(edge.redComponent > 0.3, "the rail stops short of the right edge")
        guard dump else { return }
        let cases: [(String, LibraryStore)] = [
            ("empty", try await library(count: 0)), ("one", try await library(count: 1)), ("twelve", twelve),
        ]
        for (name, store) in cases {
            let rep = try #require(snapshot(LibraryView(library: store, importer: importer(store), onOpen: { _ in }), size: size))
            try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
        }
        // A failure message showing: a drop of files that are not books.
        let store = try await library(count: 3)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-book-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: junk)
        let results = await importer(store).importAll([junk])
        #expect(results.count == 1)
        if case .failure(let error) = results[0] { #expect(error == .notAnEPUB) } else { Issue.record("expected a failure") }
        let view = LibraryView(library: store, importer: importer(store), onOpen: { _ in }, previewing: [.copyProtected, .notAnEPUB])
        let rep = try #require(snapshot(view, size: size))
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("failure.png"))
    }
}
