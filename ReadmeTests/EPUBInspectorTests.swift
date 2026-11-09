import Foundation
import Testing
@testable import Readme

private final class FixtureToken {}

private func fixture(_ name: String) throws -> URL {
    let root = try #require(Bundle(for: FixtureToken.self).url(forResource: "Fixtures", withExtension: nil))
    return root.appendingPathComponent(name)
}

@Suite struct EPUBInspectorTests {
    @Test(arguments: [
        "drm-bad-xml.epub",   // encryption.xml that does not parse
        "drm-bad-size.epub",  // declares a size it does not inflate to
        "drm-bomb.epub",      // declares nearly 4 GB
        "drm-past-end.epub",  // declares bytes beyond the end of the file
        "drm-rights.epub",    // Adobe ADEPT
        "drm-lcp.epub",       // Readium LCP
        "drm-sinf.epub",      // Apple FairPlay
    ])
    func protectedInTheseWays(name: String) throws {
        #expect(throws: ImportError.copyProtected) { try EPUBInspector.check(fixture(name)) }
    }

    @Test func aCommentThatLooksLikeAnEndRecordIsNotOne() throws {
        try EPUBInspector.check(fixture("pk-comment.epub"))
    }

    @Test func fontObfuscationAndPlainBooksPass() throws {
        try EPUBInspector.check(fixture("obfuscated.epub"))
        try EPUBInspector.check(fixture("long.epub"))
    }
}
