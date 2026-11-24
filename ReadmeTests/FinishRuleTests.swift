import Testing
@testable import Readme

private func at(_ fraction: Double, end: Bool = false) -> ReaderLocation {
    ReaderLocation(
        cfi: "epubcfi(/6/14!/4/2/10)", fraction: fraction, chapterTitle: nil, chapterMinutesLeft: 1,
        isAtStart: false, isAtEnd: end, page: 1, pageCount: 100)
}

@Suite struct FinishRuleTests {
    @Test func turningAcrossTheLineFinishes() {
        #expect(FinishRule.finishes(from: at(0.94), to: at(0.96), byTurning: true))
    }

    @Test func jumpingAcrossDoesNot() {
        #expect(!FinishRule.finishes(from: at(0.94), to: at(0.96), byTurning: false))
        #expect(!FinishRule.finishes(from: at(0.5), to: at(0.99), byTurning: false))
        #expect(!FinishRule.finishes(from: at(0.5), to: at(0.98, end: true), byTurning: false))
    }

    @Test func turningAboveTheLineDoesNot() {
        // As after Mark as Not Finished, reading on from 96%.
        #expect(!FinishRule.finishes(from: at(0.96), to: at(0.97), byTurning: true))
    }

    @Test func turningOntoTheLastSpreadFinishes() {
        #expect(FinishRule.finishes(from: at(0.97), to: at(0.98, end: true), byTurning: true))
        #expect(!FinishRule.finishes(from: at(0.98, end: true), to: at(0.98, end: true), byTurning: true))
    }

    @Test func noPlaceBeforeDoesNot() {
        #expect(!FinishRule.finishes(from: nil, to: at(0.96), byTurning: true))
    }
}
