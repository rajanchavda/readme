import Testing
@testable import Readme

@Suite struct CurlPoseTests {
    @Test func flatAtStart() { #expect(CurlPose.angles(t: 0).allSatisfy { $0 == 0 }) }
    @Test func flatAtEnd() { #expect(CurlPose.angles(t: 1).allSatisfy { $0 == -179.5 }) }
    @Test func straightAtMidpoint() { #expect(CurlPose.angles(t: 0.5).allSatisfy { abs($0 + 90) < 0.001 }) }
    @Test func outerEdgeLeadsBeforeMidpoint() {
        let a = CurlPose.angles(t: 0.25)
        #expect(a.first! == 0)
        #expect(a.last! < -40)
    }
    @Test func outerEdgeTrailsAfterMidpoint() {
        let a = CurlPose.angles(t: 0.75)
        #expect(a.first! == -179.5)
        #expect(a.last! > -140)
    }
    @Test func shadeIsDarkestEdgeOn() {
        #expect(abs(CurlPose.shade(angle: -90) - 0.16) < 0.001)
        #expect(CurlPose.shade(angle: 0) == 0)
    }
}
