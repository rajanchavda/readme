import Foundation
import Testing
@testable import Readme

@Suite struct BookFrameTests {
    /// The mockup's stage: a 980 by 552 book with 34 points of desk all round.
    @Test func theMockupsWindowShowsTheMockupsBook() {
        let layout = BookFrame(in: CGSize(width: 1048, height: 620), settings: ReaderSettings(), fullscreen: false)
        #expect(layout.frame == CGRect(x: 34, y: 34, width: 980, height: 552))
        #expect(layout.columns == 2)
        #expect(layout.fontSize == 18)
        #expect(layout.columnWidth == SpreadLayout.columnWidth(fontSize: 18, font: .ebGaramond, lineWidth: .regular))
    }

    @Test func aWideWindowKeepsTheBookCentred() {
        let layout = BookFrame(in: CGSize(width: 1600, height: 900), settings: ReaderSettings(), fullscreen: false)
        #expect(layout.frame == CGRect(x: 310, y: 34, width: 980, height: 832))
        #expect(layout.columns == 2)
    }

    @Test func aNarrowWindowShowsOneCentredPage() {
        let layout = BookFrame(in: CGSize(width: 760, height: 620), settings: ReaderSettings(), fullscreen: false)
        #expect(layout.columns == 1)
        #expect(layout.frame == CGRect(x: 100, y: 34, width: 560, height: 552))
    }

    @Test func aTallWindowShowsOnePage() {
        let layout = BookFrame(in: CGSize(width: 1048, height: 1400), settings: ReaderSettings(), fullscreen: false)
        #expect(layout.columns == 1)
    }

    /// Never narrower than the window allows, even if that's narrower than a page.
    @Test func theBookFitsTheWindow() {
        let layout = BookFrame(in: CGSize(width: 500, height: 420), settings: ReaderSettings(), fullscreen: false)
        #expect(layout.frame.minX >= 34 && layout.frame.maxX <= 466)
    }

    /// Large text only drops to one page if the window can't hold two.
    @Test func largeTextGetsAWiderSpreadWhenThereIsRoom() {
        var settings = ReaderSettings()
        settings.fontSize = 26
        let wide = BookFrame(in: CGSize(width: 1800, height: 1000), settings: settings, fullscreen: false)
        #expect(wide.columns == 2)
        #expect(wide.frame.width > 980)
        #expect(SpreadLayout.availableColumnWidth(windowWidth: wide.frame.width, columns: 2) >= wide.columnWidth)
        let narrow = BookFrame(in: CGSize(width: 1048, height: 620), settings: settings, fullscreen: false)
        #expect(narrow.columns == 1)
        #expect(SpreadLayout.availableColumnWidth(windowWidth: narrow.frame.width, columns: 1) >= narrow.columnWidth)
    }

    @Test func fullscreenHasLargerTextAndAWiderBook() {
        let layout = BookFrame(in: CGSize(width: 1728, height: 1117), settings: ReaderSettings(), fullscreen: true)
        #expect(abs(layout.fontSize - 24) < 1e-9)
        #expect(layout.columns == 2)
        #expect(abs(layout.frame.minY - 1117 * 0.03) < 1)
        #expect(layout.frame.width == BookFrame.fullscreenSpreadWidth)
    }
}

@Suite struct TimeLeftTests {
    @Test func minutesAndHours() {
        #expect(TimeLeft.text(minutes: 0.4) == "Under a minute left in chapter")
        #expect(TimeLeft.text(minutes: 1.2) == "1 min left in chapter")
        #expect(TimeLeft.text(minutes: 23) == "23 min left in chapter")
        #expect(TimeLeft.text(minutes: 60) == "1 hr left in chapter")
        #expect(TimeLeft.text(minutes: 95) == "1 hr 35 min left in chapter")
    }
}
