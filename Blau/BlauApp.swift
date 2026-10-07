import SwiftUI

/// App entry point. The composition root (environment, feature flags, model
/// container) is built on top of this in later foundation work.
@main
struct BlauApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
