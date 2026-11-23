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
        // ⌘F is Find, not fullscreen.
        #expect(action("f", [.command]) == .command(.find))
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

    /// The open contents take the plain keys, so arrows move through the list and never turn pages.
    @Test func theOpenContentsTakeThePlainKeys() {
        func inContents(_ key: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> KeyAction? {
            KeyAction.of(
                key: key, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, isFullscreen: true,
                isTyping: false, isInContents: true)
        }
        #expect(inContents(key(NSRightArrowFunctionKey), [.function, .numericPad]) == nil)
        #expect(inContents(key(NSDownArrowFunctionKey), [.function, .numericPad]) == nil)
        #expect(inContents(" ") == nil)
        #expect(inContents("f") == nil)
        #expect(inContents(key(NSEndFunctionKey), [.function]) == nil)
        #expect(inContents("\r", keyCode: 36) == nil)
        // Esc closes them, even in fullscreen, before it leaves fullscreen.
        #expect(inContents("\u{1B}", keyCode: 53) == .closeContents)
        #expect(inContents("\u{1B}", keyCode: 53, isRepeat: true) == .ignore)
        #expect(inContents("t", [.command]) == .command(.toggleTOC))
        #expect(inContents(key(NSDownArrowFunctionKey), [.command, .function, .numericPad]) == .command(.goToEnd))
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

    /// A restyle with nothing captured, as while a book opens, hasn't seen a turn.
    @Test func noCaptureHasSeenNoTurn() {
        var places = PlaceKeeper()
        let capture = places.capture("a")
        #expect(!places.hasTurned(since: capture))
        places.turned()
        #expect(places.hasTurned(since: capture))
        #expect(!places.hasTurned(since: nil))
    }

    /// A layout change shows the place on whichever page now holds it, and that page's start isn't
    /// where the reader is.
    @Test func theReadersPlaceOutlivesWhatsShown() {
        var places = PlaceKeeper()
        #expect(places.place(showing: "shown") == "shown")
        places.moved(to: "a")
        #expect(places.place(showing: "shown") == "a")
        places.moved(to: nil)
        #expect(places.place(showing: "shown") == "shown")
    }
}

/// Quitting waits for the reader's place to be written, but not for ever.
@MainActor
@Suite struct DeadlineTests {
    @Test func workThatNeverEndsIsLeftAtTheBound() async {
        let started = ContinuousClock.now
        let calls = Counter()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Deadline.wait(for: { try? await Task.sleep(for: .seconds(30)) }, atMost: .milliseconds(100)) {
                calls.count += 1
                if calls.count == 1 { done.resume() }
            }
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(calls.count == 1)
    }

    @Test func workThatEndsGoesOnOnce() async throws {
        let started = ContinuousClock.now
        let calls = Counter()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            Deadline.wait(for: {}, atMost: .milliseconds(300)) {
                calls.count += 1
                if calls.count == 1 { done.resume() }
            }
        }
        #expect(ContinuousClock.now - started < .milliseconds(300))
        try await Task.sleep(for: .milliseconds(400))
        #expect(calls.count == 1)
    }

    private final class Counter {
        var count = 0
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
    @Test func chromeOverAnEdgeTakesTheClick() async {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let (desk, turns) = edgeDesk(frame)
        let toolbar = NSView(frame: NSRect(x: 30, y: 560, width: 300, height: 40))
        desk.addSubview(toolbar)
        desk.chrome = [toolbar]
        #expect(desk.hitTest(NSPoint(x: 40, y: 570)) === toolbar)
        await click(desk, at: NSPoint(x: 40, y: 570))
        #expect(turns().isEmpty)
        toolbar.isHidden = true
        await click(desk, at: NSPoint(x: 40, y: 570))
        #expect(turns() == [.backward])
    }

    /// Chrome that lets clicks through, as the sleeping toolbar does, leaves the edge to turn pages.
    @Test func chromeThatLetsClicksThroughLeavesTheEdge() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620))
        let sleeping = PassThroughView(frame: NSRect(x: 30, y: 560, width: 300, height: 40))
        desk.addSubview(sleeping)
        desk.chrome = [sleeping]
        await click(desk, at: NSPoint(x: 40, y: 570))
        #expect(turns() == [.backward])
    }

    /// The page under the edges keeps its clicks, so text there can be selected.
    @Test func theBookUnderAnEdgeHasTheClick() {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let desk = DeskView(frame: frame, bookFrame: frame.insetBy(dx: 34, dy: 34))
        let book = NSView(frame: frame.insetBy(dx: 34, dy: 34))
        desk.addSubview(book)
        #expect(desk.hitTest(NSPoint(x: 40, y: 300)) === book)
        #expect(desk.hitTest(NSPoint(x: 1000, y: 300)) === book)
    }

    /// A drag from an edge selects, and a double or triple click on text there selects a word or a
    /// paragraph: none of them turns the page. A plain click on text turns it once, after the
    /// double-click time.
    @Test func onlyAPlainClickOnAnEdgeTurns() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620), spot: .text)
        let left = NSPoint(x: 40, y: 300), right = NSPoint(x: 1000, y: 300)

        desk.follow(mouse(.leftMouseDown, at: left, in: desk))
        desk.follow(mouse(.leftMouseDragged, at: NSPoint(x: 300, y: 300), in: desk))
        desk.follow(mouse(.leftMouseUp, at: NSPoint(x: 300, y: 300), in: desk), doubleClickInterval: 0)
        await settle()
        #expect(turns().isEmpty)

        for count in 1...3 {
            desk.follow(mouse(.leftMouseDown, at: right, clicks: count, in: desk))
            desk.follow(mouse(.leftMouseUp, at: right, clicks: count, in: desk), doubleClickInterval: 0.05)
            await Task.yield()
        }
        await settle()
        #expect(turns().isEmpty)

        desk.follow(mouse(.leftMouseDown, at: right, .shift, in: desk))
        desk.follow(mouse(.leftMouseUp, at: right, .shift, in: desk), doubleClickInterval: 0)
        await settle()
        #expect(turns().isEmpty)

        await click(desk, at: right)
        #expect(turns() == [.forward])
        await click(desk, at: NSPoint(x: 524, y: 300))
        #expect(turns() == [.forward])
    }

    /// With nothing to select under it, a click near an edge turns at once, and so does every click of
    /// a quick run, so the pages flip as fast as the clicks come.
    @Test func quickClicksOnABlankEdgeEachTurn() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620), spot: .blank)
        let right = NSPoint(x: 1000, y: 300)
        for count in 1...3 {
            desk.follow(mouse(.leftMouseDown, at: right, clicks: count, in: desk))
            desk.follow(mouse(.leftMouseUp, at: right, clicks: count, in: desk), doubleClickInterval: 10)
            await settle()
        }
        #expect(turns() == [.forward, .forward, .forward])
    }

    /// A slow page doesn't cost turns: a blank click answered after the next press still turns.
    @Test func quickClicksOnASlowBlankEdgeEachTurn() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620))
        desk.spotAt = { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                return .blank
            }
        }
        let right = NSPoint(x: 1000, y: 300)
        for count in 1...3 {
            desk.follow(mouse(.leftMouseDown, at: right, clicks: count, in: desk))
            desk.follow(mouse(.leftMouseUp, at: right, clicks: count, in: desk), doubleClickInterval: 10)
        }
        await settle()
        #expect(turns() == [.forward, .forward, .forward])
    }

    /// A quick run that started on a margin keeps turning when the new page has text under the pointer.
    @Test func aRunThatTurnedKeepsTurningOverText() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620))
        var spots: [EdgeSpot] = [.blank, .text, .text]
        desk.spotAt = { _ in
            let spot = spots.removeFirst()
            return Task { spot }
        }
        let right = NSPoint(x: 1000, y: 300)
        for count in 1...3 {
            desk.follow(mouse(.leftMouseDown, at: right, clicks: count, in: desk))
            desk.follow(mouse(.leftMouseUp, at: right, clicks: count, in: desk), doubleClickInterval: 10)
            await settle()
        }
        #expect(turns() == [.forward, .forward, .forward])
    }

    /// A blank click answered late doesn't turn the page under a drag that started meanwhile.
    @Test func aLateTurnDoesntLandInADrag() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620))
        desk.spotAt = { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(50))
                return .blank
            }
        }
        let left = NSPoint(x: 40, y: 300)
        desk.follow(mouse(.leftMouseDown, at: left, in: desk))
        desk.follow(mouse(.leftMouseUp, at: left, in: desk), doubleClickInterval: 10)
        desk.follow(mouse(.leftMouseDown, at: NSPoint(x: 524, y: 300), in: desk))
        desk.follow(mouse(.leftMouseDragged, at: NSPoint(x: 700, y: 300), in: desk))
        await settle()
        #expect(turns().isEmpty)
    }

    /// A link or a highlight has the click, so the page never turns for it: not even once a link has
    /// shown another page under the pointer.
    @Test func aClickThePageTakesNeverTurns() async {
        let (desk, turns) = edgeDesk(NSRect(x: 0, y: 0, width: 1048, height: 620), spot: .own)
        await click(desk, at: NSPoint(x: 1000, y: 300))
        #expect(turns().isEmpty)
    }

    /// What's under the click is asked as the button goes down, before a link can change the page.
    @Test func theSpotIsAskedOnThePress() async {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let (desk, turns) = edgeDesk(frame, spot: .blank)
        var asked: [NSPoint] = []
        var spot = EdgeSpot.own
        desk.spotAt = { point in
            asked.append(point)
            let answer = spot
            return Task { answer }
        }
        let right = NSPoint(x: 1000, y: 300)
        desk.follow(mouse(.leftMouseDown, at: right, in: desk))
        #expect(asked == [right])
        spot = .blank
        desk.follow(mouse(.leftMouseUp, at: right, in: desk), doubleClickInterval: 0)
        await settle()
        #expect(asked == [right])
        #expect(turns().isEmpty)
    }

    /// A turn that's waiting out the double-click time goes when the reader moves on, but not for a
    /// press on the toolbar.
    @Test func aWaitingTurnCanBeDropped() async {
        let frame = NSRect(x: 0, y: 0, width: 1048, height: 620)
        let (desk, turns) = edgeDesk(frame, spot: .text)
        let toolbar = NSView(frame: NSRect(x: 30, y: 560, width: 300, height: 40))
        desk.addSubview(toolbar)
        desk.chrome = [toolbar]
        let right = NSPoint(x: 1000, y: 300)

        desk.follow(mouse(.leftMouseDown, at: right, in: desk))
        desk.follow(mouse(.leftMouseUp, at: right, in: desk), doubleClickInterval: 0.1)
        await Task.yield()
        desk.follow(mouse(.leftMouseDown, at: NSPoint(x: 40, y: 570), clicks: 2, in: desk))
        desk.follow(mouse(.leftMouseUp, at: NSPoint(x: 40, y: 570), clicks: 2, in: desk))
        await settle()
        #expect(turns() == [.forward])

        desk.follow(mouse(.leftMouseDown, at: right, in: desk))
        desk.follow(mouse(.leftMouseUp, at: right, in: desk), doubleClickInterval: 0.1)
        await Task.yield()
        desk.cancelEdgeTurn()
        await settle()
        #expect(turns() == [.forward])
    }

    @Test func whatAnEdgeClickDoesGoesByWhatsUnderIt() {
        #expect(EdgeClick.turn(for: .own, clickCount: 1) == .none)
        #expect(EdgeClick.turn(for: .blank, clickCount: 1) == .now)
        #expect(EdgeClick.turn(for: .blank, clickCount: 3) == .now)
        #expect(EdgeClick.turn(for: .text, clickCount: 1) == .afterDoubleClick)
        #expect(EdgeClick.turn(for: .text, clickCount: 2) == .none)
        #expect(EdgeClick.turn(for: .text, clickCount: 2, runHasTurned: true) == .now)
        #expect(EdgeClick.turn(for: .text, clickCount: 1, runHasTurned: true) == .afterDoubleClick)
        #expect(EdgeClick.turn(for: .own, clickCount: 2, runHasTurned: true) == .none)
    }

    @Test func aClickTrembleIsStillAClick() {
        var click = EdgeClick()
        click.press(at: NSPoint(x: 40, y: 300), direction: .backward, clickCount: 1, isPlain: true)
        click.drag(to: NSPoint(x: 42, y: 302))
        #expect(click.release(at: NSPoint(x: 43, y: 301))?.direction == .backward)
        click.press(at: NSPoint(x: 40, y: 300), direction: .backward, clickCount: 1, isPlain: true)
        click.drag(to: NSPoint(x: 50, y: 300))
        click.drag(to: NSPoint(x: 40, y: 300))
        #expect(click.release(at: NSPoint(x: 40, y: 300)) == nil)
    }

    private func edgeDesk(_ frame: NSRect, spot: EdgeSpot = .blank) -> (DeskView, () -> [TurnDirection]) {
        let desk = DeskView(frame: frame, bookFrame: frame.insetBy(dx: 34, dy: 34))
        var turns: [TurnDirection] = []
        desk.onEdgeClick = { turns.append($0) }
        desk.spotAt = { _ in Task { spot } }
        return (desk, { turns })
    }

    private func click(_ desk: DeskView, at point: NSPoint) async {
        desk.follow(mouse(.leftMouseDown, at: point, in: desk))
        desk.follow(mouse(.leftMouseUp, at: point, in: desk), doubleClickInterval: 0)
        await settle()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, clicks: Int = 1, _ modifiers: NSEvent.ModifierFlags = [],
        in desk: DeskView
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: desk.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// The spine's shadow belongs to the pages, so the turning page passes over it.
    @Test func theSpineIsNeverAboveTheCurl() async throws {
        let reader = ReaderWindowController()
        defer { reader.window?.close() }
        await reader.open(try fixture("long.epub"), at: nil)
        let desk = reader.deskView
        let spine = try #require(desk.subviews.firstIndex { $0 is SpineView })
        let curl = try #require(desk.subviews.firstIndex { $0 is CurlView })
        let book = try #require(desk.subviews.firstIndex { $0 is BookWebView })
        #expect(book < spine)
        #expect(spine < curl)
    }
}
