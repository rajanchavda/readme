import CoreGraphics
import Testing
@testable import Readme

@Suite struct ChipRowLayoutTests {
    private func fit(_ widths: [CGFloat], active: Int = 0, available: CGFloat) -> ChipFit {
        ChipRowLayout.fit(widths: widths, active: active, available: available, moreWidth: 80, addWidth: 30)
    }

    @Test func allFit() {
        #expect(fit([50, 80, 70], available: 400) == ChipFit(visible: [0, 1, 2], overflow: []))
    }

    @Test func someGoToMore() {
        #expect(fit([50, 90, 90, 90, 90], available: 460) == ChipFit(visible: [0, 1, 2], overflow: [3, 4]))
    }

    @Test func activeIsSwappedIn() {
        #expect(fit([50, 90, 90, 90, 90], active: 4, available: 460) == ChipFit(visible: [0, 1, 4], overflow: [2, 3]))
    }

    @Test func tooNarrowKeepsAll() {
        #expect(fit([50, 90], available: 120) == ChipFit(visible: [0], overflow: [1]))
        // Even with the other one active, All stays and the active one is a menu item away.
        #expect(fit([50, 90], active: 1, available: 120) == ChipFit(visible: [0], overflow: [1]))
    }

    @Test func lessRoomWithSearchOpen() {
        let widths: [CGFloat] = [50, 96, 88, 76, 80, 92, 104, 82, 92, 110, 74]
        let closed = fit(widths, active: 8, available: 848)
        let open = fit(widths, active: 8, available: 636)
        #expect(open.visible.count <= closed.visible.count)
        #expect(closed.visible.contains(8))
        #expect(open.visible.contains(8))
        #expect(open.visible.count + open.overflow.count == widths.count)
    }
}
