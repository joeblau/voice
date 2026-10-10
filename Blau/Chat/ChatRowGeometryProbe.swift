#if DEBUG
    import SwiftUI

    extension EnvironmentValues {
        @Entry var reportsChatRowFrames = false
    }

    /// UIKit's accessibility frame for selectable text can include the
    /// scroll container rather than the rendered text's margins on iOS 27.
    /// UI tests read SwiftUI's actual layout, as they already do for the
    /// timeline's expansion latency. Live launches never enable this probe.
    struct ChatRowGeometryProbe: ViewModifier {
        let identifier: String
        @Environment(\.reportsChatRowFrames) private var reportsFrames
        @State private var rectangle = CGRect.zero

        func body(content: Content) -> some View {
            if reportsFrames {
                content
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        rectangle = $0
                    }
                    .overlay(alignment: .topLeading) {
                        Text("")
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Transcript row layout")
                            .accessibilityValue(Text(verbatim: geometryValue))
                            .accessibilityIdentifier("\(identifier).geometry")
                    }
            } else {
                content
            }
        }

        private var geometryValue: String {
            "\(rectangle.minX),\(rectangle.minY),\(rectangle.width),\(rectangle.height)"
        }
    }
#endif
