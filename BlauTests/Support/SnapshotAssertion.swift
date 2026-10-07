import Foundation
import SwiftUI
import Testing
import UIKit

/// Image snapshots for views drawn purely in SwiftUI (no UIKit-backed
/// controls, which `ImageRenderer` can't draw), compared with reference
/// PNGs committed next to the test.
///
/// References live in `__Snapshots__/<suite file>/<name>@ios<major>.png`
/// beside the test file and are read through `#filePath`: the simulator
/// shares the Mac's file system, so they don't need to be bundled. They are
/// keyed by the iOS major version because SF Symbols and antialiasing can
/// change between releases.
///
/// - A missing reference fails the test and writes the rendered image to
///   the temporary directory (the failure says where).
/// - `BLAU_RECORD_SNAPSHOTS=1` (pass `TEST_RUNNER_BLAU_RECORD_SNAPSHOTS=1`
///   to `xcodebuild test`) writes every rendered image as the new reference
///   and fails, so a recording run is never mistaken for a passing one.
/// - Comparison allows small antialiasing differences: a pixel differs when
///   any channel is off by more than `channelTolerance`, and up to
///   `pixelTolerance` of the pixels may differ.
@MainActor
struct SnapshotAssertion {
    /// Points to pixels. Fixed, so the device the tests run on doesn't
    /// matter.
    static let scale: CGFloat = 3
    static let channelTolerance = 24
    static let pixelTolerance = 0.005

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["BLAU_RECORD_SNAPSHOTS"] == "1"
    }

    static var osSuffix: String {
        "ios\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }

    /// Renders `view` at `size` points and compares it with the reference
    /// named `name`.
    static func assert(
        _ view: some View,
        size: CGSize,
        named name: String,
        filePath: String = #filePath,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let renderer = ImageRenderer(
            content:
                view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.uiImage, let png = image.pngData() else {
            Issue.record("Couldn't render \(name)", sourceLocation: sourceLocation)
            return
        }

        let testFile = URL(fileURLWithPath: filePath)
        let directory = testFile.deletingLastPathComponent()
            .appending(path: "__Snapshots__", directoryHint: .isDirectory)
            .appending(path: testFile.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
        let reference = directory.appending(path: "\(name)@\(osSuffix).png")

        if isRecording {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: reference)
                Issue.record(
                    "Recorded \(reference.lastPathComponent). Run again without BLAU_RECORD_SNAPSHOTS to compare.",
                    sourceLocation: sourceLocation)
            } catch {
                Issue.record("Couldn't record \(reference.path): \(error)", sourceLocation: sourceLocation)
            }
            return
        }

        guard let expected = try? Data(contentsOf: reference) else {
            let actual = FileManager.default.temporaryDirectory.appending(path: "\(name)@\(osSuffix).png")
            try? png.write(to: actual)
            Issue.record(
                """
                No reference \(reference.lastPathComponent) for \(osSuffix). Rendered image: \(actual.path). \
                Record references with TEST_RUNNER_BLAU_RECORD_SNAPSHOTS=1.
                """,
                sourceLocation: sourceLocation)
            return
        }

        switch compare(png, expected) {
        case .match:
            break
        case .mismatch(let reason):
            let actual = FileManager.default.temporaryDirectory.appending(path: "\(name)@\(osSuffix).actual.png")
            try? png.write(to: actual)
            Issue.record(
                "\(name) doesn't match \(reference.lastPathComponent): \(reason). Rendered image: \(actual.path)",
                sourceLocation: sourceLocation)
        }
    }

    enum Comparison: Equatable {
        case match
        case mismatch(String)
    }

    /// Compares two PNGs pixel by pixel within the tolerances.
    static func compare(_ actualPNG: Data, _ expectedPNG: Data) -> Comparison {
        guard let actual = Bitmap(png: actualPNG), let expected = Bitmap(png: expectedPNG) else {
            return .mismatch("unreadable image")
        }
        guard actual.width == expected.width, actual.height == expected.height else {
            return .mismatch("size \(actual.width)x\(actual.height), expected \(expected.width)x\(expected.height)")
        }
        var differing = 0
        for pixel in 0..<(actual.width * actual.height) {
            let offset = pixel * 4
            for channel in 0..<4
            where abs(Int(actual.bytes[offset + channel]) - Int(expected.bytes[offset + channel])) > channelTolerance {
                differing += 1
                break
            }
        }
        let fraction = Double(differing) / Double(actual.width * actual.height)
        return fraction <= pixelTolerance
            ? .match : .mismatch("\(differing) pixels (\(String(format: "%.2f", fraction * 100))%) differ")
    }

    /// Premultiplied RGBA8, so the same picture compares equal however the
    /// PNG was encoded.
    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]

        init?(png: Data) {
            guard let image = UIImage(data: png)?.cgImage else { return nil }
            let width = image.width
            let height = image.height
            self.width = width
            self.height = height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.bytes = bytes
        }
    }
}
