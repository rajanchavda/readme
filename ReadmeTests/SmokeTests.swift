import Foundation
import Testing
@testable import Readme

@Suite struct SmokeTests {
    @Test func appIdentity() {
        #expect(Bundle(for: BundleToken.self).bundleIdentifier == "com.rajanchavda.Readme")
    }
}
