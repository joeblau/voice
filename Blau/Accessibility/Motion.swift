import SwiftUI

/// Reduce Motion alternatives (#81, docs/accessibility.md).
///
/// With Reduce Motion on, nothing on Blau's screens slides, grows or
/// pulses: cards and pills fade in place instead of sliding in, the level
/// ring keeps its size and only its opacity follows the level, the topic
/// dot wears a steady halo instead of a pulse, the spinner is a static
/// ellipsis, and springs become a short ease. Views read
/// `accessibilityReduceMotion` and pick from these.
enum Motion {
    /// Slides in from `edge` while fading in, or only fades under Reduce
    /// Motion.
    static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// `animation`, or a short cross-fade under Reduce Motion: state
    /// changes still read as changes, without movement.
    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : animation
    }
}
