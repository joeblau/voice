import SwiftUI
import WidgetKit

/// The BlauWidgets extension. Today it only renders the recording Live
/// Activity (#26); home-screen widgets would go here too.
@main
struct BlauWidgetsBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
    }
}
