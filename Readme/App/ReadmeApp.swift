import SwiftUI

/// Anchor class so tests can locate the app bundle via `Bundle(for:)`.
final class BundleToken {}

@main
struct ReadmeApp: App {
    var body: some Scene {
        WindowGroup {
            Color.clear.frame(minWidth: 400, minHeight: 300)
        }
    }
}
