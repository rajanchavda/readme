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
    let name = "ThemeTurnTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

/// The image's pixels as sRGB bytes.
private func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (bytes, width, height)
}

/// How many pixels are within a few levels of `color` in every channel.
private func count(of color: NSColor, in image: CGImage) -> Int {
    let c = color.usingColorSpace(.sRGB)!
    let target = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    let (bytes, width, height) = pixels(image)
    var found = 0
    for i in stride(from: 0, to: width * height * 4, by: 4)
    where abs(Int(bytes[i]) - target[0]) <= 3 && abs(Int(bytes[i + 1]) - target[1]) <= 3
        && abs(Int(bytes[i + 2]) - target[2]) <= 3 {
        found += 1
    }
    return found
}

/// Where the pixels near `color` are: their bounding box, and how many lie inside the text area.
func whereIs(_ color: NSColor, in image: CGImage) -> String {
    let c = color.usingColorSpace(.sRGB)!
    let target = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    let (bytes, width, height) = pixels(image)
    var minX = width, minY = height, maxX = 0, maxY = 0, inner = 0, total = 0
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            guard abs(Int(bytes[i]) - target[0]) <= 3 && abs(Int(bytes[i + 1]) - target[1]) <= 3
                && abs(Int(bytes[i + 2]) - target[2]) <= 3 else { continue }
            total += 1
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            if x > width / 10 && x < width * 9 / 10 && y > height / 10 && y < height * 9 / 10 { inner += 1 }
        }
    }
    return "\(total) of \(width)x\(height) px, box x \(minX)...\(maxX) y \(minY)...\(maxY), \(inner) inside the middle 80%"
}

/// After a theme change, nothing a turn shows, whether curl, drag or crossfade, carries the old
/// theme's paper.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5))) struct ThemeTurnTests {
    nonisolated static let changes: [(ThemeChoice, ThemeChoice)] = [
        (.paper, .sepia), (.sepia, .paper), (.paper, .night), (.night, .sepia), (.sepia, .night), (.night, .paper),
    ]

    @Test(arguments: changes)
    func theTurningPagesTakeTheNewTheme(from old: ThemeChoice, to new: ThemeChoice) async throws {
        let defaults = scratchDefaults()
        var settings = ReaderSettings()
        settings.theme = old
        settings.save(defaults)
        let reader = ReaderWindowController(defaults: defaults)
        defer { reader.window?.close() }
        reader.window?.setFrameAutosaveName("")
        reader.window?.setContentSize(NSSize(width: 1048, height: 620))
        reader.window?.orderFrontRegardless()
        await reader.open(try fixture("long.epub"))
        await reader.settled()
        reader.goToPage(typed: "20")
        await reader.settled()
        let before = await reader.spreadImages()
        try #require(before.count == 3)

        settings.theme = new
        reader.change(settings)
        await reader.settled()
        let after = await reader.spreadImages()
        try #require(after.count == 3)
        let oldPaper = ReadingCSS.colors(old == .paper ? .paper : old == .sepia ? .sepia : .night).page
        let newPaper = ReadingCSS.colors(new == .paper ? .paper : new == .sepia ? .sepia : .night).page
        for (slot, image) in zip(["current", "next", "previous"], after) {
            #expect(count(of: newPaper, in: image) > 0, "\(slot) has none of the new paper")
            #expect(count(of: oldPaper, in: image) == 0, "\(slot) still shows the old paper: \(whereIs(oldPaper, in: image))")
        }
    }

    /// Auto follows the Mac into dark mode, and the turning pages follow it too.
    @Test func autoFollowingDarkModeReachesTheTurningPages() async throws {
        let defaults = scratchDefaults()
        var settings = ReaderSettings()
        settings.theme = .auto
        settings.save(defaults)
        let reader = ReaderWindowController(defaults: defaults)
        defer { reader.window?.close() }
        reader.window?.appearance = NSAppearance(named: .aqua)
        reader.window?.setFrameAutosaveName("")
        reader.window?.setContentSize(NSSize(width: 1048, height: 620))
        reader.window?.orderFrontRegardless()
        await reader.open(try fixture("long.epub"))
        await reader.settled()
        reader.goToPage(typed: "20")
        await reader.settled()
        try #require(await reader.spreadImages().count == 3)

        reader.window?.appearance = NSAppearance(named: .darkAqua)
        // The appearance reaches the desk on the next pass of the run loop.
        try await Task.sleep(for: .milliseconds(100))
        await reader.settled()
        let after = await reader.spreadImages()
        try #require(after.count == 3)
        for (slot, image) in zip(["current", "next", "previous"], after) {
            #expect(count(of: ReadingCSS.colors(.night).page, in: image) > 0, "\(slot) has none of the night paper")
            #expect(count(of: ReadingCSS.colors(.paper).page, in: image) == 0,
                    "\(slot) still shows the old paper: \(whereIs(ReadingCSS.colors(.paper).page, in: image))")
        }
    }
}
