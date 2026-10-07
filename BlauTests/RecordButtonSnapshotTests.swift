import BlauRealtime
import SwiftUI
import Testing

@testable import Blau

/// Snapshots of the record button's face in every state (#41), on its
/// state's tint as the bottom bar's prominent glass shows it. The levels are
/// fixed so the rings are deterministic: the microphone at 0.75 while
/// listening, Grok at 0.6 while speaking.
///
/// Record new references after an intended visual change with
/// `TEST_RUNNER_BLAU_RECORD_SNAPSHOTS=1` (see `SnapshotAssertion`), then
/// check the PNGs in `__Snapshots__/RecordButtonSnapshotTests/` before
/// committing them.
@Suite("Record button snapshots")
@MainActor
struct RecordButtonSnapshotTests {
    nonisolated static let states: [(name: String, state: RecordButtonState)] = [
        ("idle", .idle),
        ("connecting", .connecting),
        ("listening", .listening),
        ("agentSpeaking", .agentSpeaking),
        ("paused", .paused),
        ("stopping", .stopping),
        ("error-couldNotStart", .error(.couldNotStart(message: "No microphone"))),
        ("error-connection", .error(.connection(requiresUserAction: false))),
        ("error-audioInterrupted", .error(.audioInterrupted)),
    ]

    /// The face on its tint, padded like the bar's capsule.
    private func button(_ state: RecordButtonState, input: Float, output: Float, reducesMotion: Bool = false)
        -> some View
    {
        RecordButtonFace(state: state, inputLevel: input, outputLevel: output, reducesMotion: reducesMotion)
            .padding(10)
            .background(RecordButtonFace.tint(for: state), in: .circle)
    }

    private static let size = CGSize(width: 46, height: 46)

    @Test(arguments: states.map(\.name))
    func everyState(name: String) throws {
        let state = try #require(Self.states.first { $0.name == name }?.state)
        SnapshotAssertion.assert(button(state, input: 0.75, output: 0.6), size: Self.size, named: name)
    }

    /// The ring at its extremes: a quiet room and a loud voice.
    @Test func listeningRingFollowsTheLevel() {
        SnapshotAssertion.assert(
            button(.listening, input: 0, output: 0), size: Self.size, named: "listening-silent")
        SnapshotAssertion.assert(button(.listening, input: 1, output: 0), size: Self.size, named: "listening-loud")
    }

    /// Reduce Motion: the ring keeps its size (only its opacity follows the
    /// level) and the spinner is a static ellipsis.
    @Test func reduceMotion() {
        SnapshotAssertion.assert(
            button(.listening, input: 0.2, output: 0, reducesMotion: true), size: Self.size,
            named: "listening-reduceMotion")
        SnapshotAssertion.assert(
            button(.connecting, input: 0, output: 0, reducesMotion: true), size: Self.size,
            named: "connecting-reduceMotion")
    }

    /// The ring's size is the level when motion is allowed and fixed when
    /// it isn't: two levels give different images, or the same one.
    @Test func reduceMotionKeepsTheRingStill() throws {
        func png(_ level: Float, reducesMotion: Bool) throws -> Data {
            let renderer = ImageRenderer(
                content: button(.listening, input: level, output: 0, reducesMotion: reducesMotion)
                    .frame(width: Self.size.width, height: Self.size.height))
            renderer.scale = SnapshotAssertion.scale
            return try #require(renderer.uiImage?.pngData())
        }
        #expect(
            SnapshotAssertion.compare(try png(0.1, reducesMotion: false), try png(0.9, reducesMotion: false)) != .match)
        // Opacity still follows the level, so compare the shapes' extent
        // instead: with Reduce Motion the ring's bounding box doesn't move.
        // Antialiasing at a faint ring's edge can move it by a pixel or two;
        // growing with the level moves it by about 20 px (at 3x).
        let stillQuiet = try ringExtent(png(0.1, reducesMotion: true))
        let stillLoud = try ringExtent(png(0.9, reducesMotion: true))
        #expect(abs(stillQuiet.width - stillLoud.width) <= 3, "\(stillQuiet) vs \(stillLoud)")
        let movingQuiet = try ringExtent(png(0.1, reducesMotion: false))
        let movingLoud = try ringExtent(png(0.9, reducesMotion: false))
        #expect(movingLoud.width - movingQuiet.width >= 12, "\(movingQuiet) vs \(movingLoud)")
    }

    /// The bounding box of the white (ring and glyph) pixels.
    private func ringExtent(_ png: Data) throws -> CGRect {
        let image = try #require(UIImage(data: png)?.cgImage)
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                // Whitish over the red tint: high green and blue.
                if bytes[offset + 1] > 100, bytes[offset + 2] > 100 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
