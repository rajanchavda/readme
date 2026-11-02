import AppKit
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

private func key(_ code: Int) -> String { String(UnicodeScalar(UInt16(code))!) }

/// The reading window's keys, as its key monitor reads them.
@Suite struct KeyActionTests {
    private func action(
        _ key: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
        isFullscreen: Bool = false, isTyping: Bool = false
    ) -> KeyAction? {
        KeyAction.of(
            key: key, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, isFullscreen: isFullscreen,
            isTyping: isTyping)
    }

    @Test func arrowsAndSpaceTurnAndPassTheRepeatOn() {
        #expect(action(key(NSRightArrowFunctionKey), [.function, .numericPad]) == .turn(.forward, isRepeat: false))
        #expect(action(key(NSRightArrowFunctionKey), isRepeat: true) == .turn(.forward, isRepeat: true))
        #expect(action(key(NSLeftArrowFunctionKey), isRepeat: true) == .turn(.backward, isRepeat: true))
        #expect(action(" ") == .turn(.forward, isRepeat: false))
        #expect(action(" ", isRepeat: true) == .turn(.forward, isRepeat: true))
    }

    @Test func turnsNeedNoCommandControlOrOption() {
        #expect(action(key(NSRightArrowFunctionKey), [.command]) == nil)
        #expect(action(key(NSLeftArrowFunctionKey), [.option]) == nil)
        #expect(action(" ", [.control]) == nil)
    }

    @Test func keysTypedIntoAFieldAreTheFields() {
        #expect(action("f", isTyping: true) == nil)
        #expect(action(" ", isTyping: true) == nil)
        #expect(action(key(NSRightArrowFunctionKey), isTyping: true) == nil)
        #expect(action(key(NSHomeFunctionKey), isTyping: true) == nil)
    }

    @Test func onlyPlainFTogglesFullscreen() {
        #expect(action("f") == .command(.toggleFullscreen))
        #expect(action("F", [.shift]) == nil)
        #expect(action("f", [.command]) == nil)
        #expect(action("f", [.control, .command]) == .command(.toggleFullscreen))
    }

    @Test func homeAndEndAreCommandsNotTurns() {
        #expect(action(key(NSHomeFunctionKey), [.function]) == .command(.goToStart))
        #expect(action(key(NSEndFunctionKey), [.function]) == .command(.goToEnd))
    }

    /// Holding F mustn't flicker in and out of fullscreen, but holding ⌘+ keeps growing the text.
    @Test func onlyTextSizeRepeats() {
        #expect(action("f", isRepeat: true) == .ignore)
        #expect(action("f", [.control, .command], isRepeat: true) == .ignore)
        #expect(action(key(NSHomeFunctionKey), isRepeat: true) == .ignore)
        #expect(action("t", [.command], isRepeat: true) == .ignore)
        #expect(action("=", [.command], isRepeat: true) == .command(.biggerText))
        #expect(action("-", [.command], isRepeat: true) == .command(.smallerText))
    }

    @Test func escapeLeavesFullscreenOnly() {
        #expect(action("\u{1B}", keyCode: 53, isFullscreen: true) == .leaveFullscreen)
        #expect(action("\u{1B}", keyCode: 53, isFullscreen: false) == nil)
        #expect(action("\u{1B}", keyCode: 53, isRepeat: true, isFullscreen: true) == .ignore)
    }
}

/// Where the window goes back to after its layout changes.
@Suite struct PlaceKeeperTests {
    @Test func aCaptureGoesBackToItsPlace() {
        let places = PlaceKeeper()
        #expect(places.target(places.capture("a")) == "a")
        #expect(places.capture(nil) == nil)
    }

    @Test func aTurnSinceTheCaptureWins() {
        var places = PlaceKeeper()
        let capture = places.capture("a")
        places.turned()
        #expect(places.target(capture) == nil)
    }

    @Test func aLayoutChangeKeepsItsFirstPlace() {
        var places = PlaceKeeper()
        places.beginLayoutChange(at: "a")
        places.beginLayoutChange(at: "b")
        #expect(places.target(places.layoutChangeCapture) == "a")
        #expect(places.target(places.endLayoutChange()) == "a")
    }

    /// A live resize that never changed the size leaves nothing behind for a later restyle.
    @Test func endingALayoutChangeClearsIt() {
        var places = PlaceKeeper()
        places.beginLayoutChange(at: "a")
        _ = places.endLayoutChange()
        #expect(places.layoutChangeCapture == nil)
        #expect(places.endLayoutChange() == nil)
        #expect(places.target(places.capture("b")) == "b")
    }

    @Test func aTurnDuringALayoutChangeIsKept() {
        var places = PlaceKeeper()
        places.beginLayoutChange(at: "a")
        places.turned()
        #expect(places.target(places.endLayoutChange()) == nil)
    }
}

@MainActor
@Suite struct ReaderWindowChromeTests {
    @Test func trafficLightsShowOnlyInTheTitleBarStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 1048, height: 620)
        #expect(ReaderWindowController.showsTrafficLights(at: NSPoint(x: 500, y: 610), in: bounds, titleBarHeight: 28))
        #expect(ReaderWindowController.showsTrafficLights(at: NSPoint(x: 10, y: 593), in: bounds, titleBarHeight: 28))
        #expect(!ReaderWindowController.showsTrafficLights(at: NSPoint(x: 10, y: 590), in: bounds, titleBarHeight: 28))
        #expect(!ReaderWindowController.showsTrafficLights(at: NSPoint(x: 500, y: 300), in: bounds, titleBarHeight: 28))
        #expect(!ReaderWindowController.showsTrafficLights(at: NSPoint(x: 500, y: 630), in: bounds, titleBarHeight: 28))
    }

    /// In fullscreen the system's reveal bar owns them, and it needs them visible wherever the pointer is.
    @Test func fullscreenLeavesTrafficLightsToTheSystem() {
        let bounds = NSRect(x: 0, y: 0, width: 1512, height: 949)
        #expect(ReaderWindowController.showsTrafficLights(
            at: NSPoint(x: 500, y: 300), in: bounds, titleBarHeight: 0, isFullscreen: true))
        #expect(ReaderWindowController.showsTrafficLights(
            at: NSPoint(x: 500, y: 945), in: bounds, titleBarHeight: 0, isFullscreen: true))
        #expect(!ReaderWindowController.showsTrafficLights(
            at: NSPoint(x: 500, y: 945), in: bounds, titleBarHeight: 0, isFullscreen: false))
    }

    /// The toolbar can overlap the page's outer band, and a click on it mustn't turn the page.
    @Test func chromeOverAnEdgeTakesTheClick() {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let desk = DeskView(frame: frame, bookFrame: frame.insetBy(dx: 34, dy: 34))
        let toolbar = NSView(frame: NSRect(x: 30, y: 560, width: 300, height: 40))
        desk.addSubview(toolbar)
        desk.chrome = [toolbar]
        #expect(desk.hitTest(NSPoint(x: 40, y: 570)) === toolbar)
        #expect(desk.hitTest(NSPoint(x: 40, y: 300)) === desk)
        toolbar.isHidden = true
        #expect(desk.hitTest(NSPoint(x: 40, y: 570)) === desk)
    }

    /// Chrome that lets clicks through, as the sleeping toolbar does, leaves the edge to turn pages.
    @Test func chromeThatLetsClicksThroughLeavesTheEdge() {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let desk = DeskView(frame: frame, bookFrame: frame.insetBy(dx: 34, dy: 34))
        let sleeping = PassThroughView(frame: NSRect(x: 30, y: 560, width: 300, height: 40))
        desk.addSubview(sleeping)
        desk.chrome = [sleeping]
        #expect(desk.hitTest(NSPoint(x: 40, y: 570)) === desk)
    }

    /// The spine's shadow belongs to the pages, so the turning page passes over it.
    @Test func theSpineIsNeverAboveTheCurl() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        let desk = try #require(reader.window?.contentView)
        let spine = try #require(desk.subviews.firstIndex { $0 is SpineView })
        let curl = try #require(desk.subviews.firstIndex { $0 is CurlView })
        let book = try #require(desk.subviews.firstIndex { $0 is BookWebView })
        #expect(book < spine)
        #expect(spine < curl)
    }
}
