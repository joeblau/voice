import SwiftUI

extension View {
    /// In Debug builds (or with the `BLAU_BENCHMARKS` condition), adds a
    /// small button that opens the on-device benchmark screen, which also
    /// opens at launch with the `-BlauBenchmarks` argument. Does nothing in
    /// other builds.
    func debugBenchmarksEntry() -> some View {
        #if DEBUG || BLAU_BENCHMARKS
            modifier(DebugBenchmarksEntry())
        #else
            self
        #endif
    }
}

#if DEBUG || BLAU_BENCHMARKS
    private struct DebugBenchmarksEntry: ViewModifier {
        nonisolated static let accessibilityIdentifier = "blau.debug.benchmarks"

        @State private var isPresented = ProcessInfo.processInfo.arguments.contains("-BlauBenchmarks")

        func body(content: Content) -> some View {
            content
                .overlay(alignment: .topTrailing) {
                    Button {
                        isPresented = true
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .padding(12)
                    }
                    .accessibilityLabel("Benchmarks")
                    .accessibilityIdentifier(Self.accessibilityIdentifier)
                }
                .sheet(isPresented: $isPresented) {
                    BenchmarkView()
                }
        }
    }
#endif
