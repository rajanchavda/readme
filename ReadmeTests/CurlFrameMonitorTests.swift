import AppKit
import Foundation
import Testing
@testable import Readme

struct CurlFrameTallyTests {
    private let period = 1.0 / 120

    /// Ticks at `slots` frames from the start, each arriving just after its timestamp.
    private func tally(slots: [Int]) -> CurlFrameTally {
        var tally = CurlFrameTally()
        for slot in slots {
            let timestamp = 100 + Double(slot) * period
            tally.tick(timestamp: timestamp, target: timestamp + period, now: timestamp + 0.001)
        }
        return tally
    }

    @Test func anUnbrokenRunMissesNothing() {
        let result = tally(slots: Array(0...60))
        #expect(result.frames == 60)
        #expect(result.missed == 0)
        #expect(result.late == 0)
        #expect(abs(result.longest - period) < 0.0001)
        #expect(abs(result.refreshRate - 120) < 0.5)
    }

    @Test func aGapCountsTheFramesItSkipped() {
        let result = tally(slots: [0, 1, 2, 7, 8])
        #expect(result.frames == 8)
        #expect(result.missed == 4)
        #expect(abs(result.longest - 5 * period) < 0.0001)
    }

    @Test func aTickArrivingAfterItsTargetIsLateButNotMissed() {
        var tally = CurlFrameTally()
        tally.tick(timestamp: 100, target: 100 + period, now: 100 + 0.001)
        let next = 100 + period
        tally.tick(timestamp: next, target: next + period, now: next + period + 0.001)
        #expect(tally.missed == 0)
        #expect(tally.late == 1)
    }

    @Test func aPoseFinishedAfterItsTargetIsLateOnceForThatFrame() {
        var tally = CurlFrameTally()
        tally.tick(timestamp: 100, target: 100 + period, now: 100 + period + 0.001)
        tally.posed(target: 100 + period, now: 100 + period + 0.002)
        #expect(tally.late == 1)
        #expect(tally.tightestMargin < 0)
    }

    @Test func thePoseWithTheLeastTimeToSpareIsKept() {
        var tally = CurlFrameTally()
        tally.posed(target: 100, now: 99.995)
        tally.posed(target: 101, now: 100.999)
        tally.posed(target: 102, now: 101.990)
        #expect(abs(tally.tightestMargin - 0.001) < 0.0001)
        #expect(tally.late == 0)
    }

    @Test func noTicksAtAllReportNothingMissedAndNoRate() {
        let result = CurlFrameTally()
        #expect(result.frames == 0)
        #expect(result.missed == 0)
        #expect(result.refreshRate == 0)
    }
}

/// On screen, because display links don't tick without one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct CurlFrameMonitorTests {
    private func page(_ gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        return try #require(context.makeImage())
    }

    private func curl(in window: NSWindow) throws -> CurlView {
        let view = CurlView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        window.contentView = view
        return view
    }

    private func onScreenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    @Test func aPlayedTurnReportsOnceWithItsFrames() async throws {
        let window = onScreenWindow()
        defer { window.orderOut(nil) }
        let view = try curl(in: window)
        var summaries: [CurlFrameSummary] = []
        view.frameMonitor.onSummary = { summaries.append($0) }

        view.begin(
            .forward, front: try page(0.1), back: try page(0.3), beneathLeft: try page(0.5), beneathRight: try page(0.7))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            view.play(from: 0, to: 1) { done.resume() }
        }
        view.end()

        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.direction == .forward)
        #expect(summary.tally.frames > 0)
        #expect(summary.isFollowed == false)
    }

    @Test func aHeldPageIsMeasuredWithNothingPlaying() async throws {
        let window = onScreenWindow()
        defer { window.orderOut(nil) }
        let view = try curl(in: window)
        var summaries: [CurlFrameSummary] = []
        view.frameMonitor.onSummary = { summaries.append($0) }

        view.begin(
            .backward, front: try page(0.1), back: try page(0.3), beneathLeft: try page(0.5), beneathRight: try page(0.7))
        view.setProgress(0.8)
        view.setProgress(0.7)
        try await Task.sleep(for: .milliseconds(200))
        view.end()

        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(summary.direction == .backward)
        #expect(summary.tally.frames > 0)
        #expect(summary.isFollowed)
    }

    @Test func aCurlNobodyShowsReportsNothing() throws {
        let window = onScreenWindow()
        defer { window.orderOut(nil) }
        let view = try curl(in: window)
        var summaries: [CurlFrameSummary] = []
        view.frameMonitor.onSummary = { summaries.append($0) }

        view.end()

        #expect(summaries.isEmpty)
    }
}
