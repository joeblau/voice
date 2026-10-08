// swift-tools-version: 6.2
//
// BlauKitBenchmarks: micro-benchmarks of BlauKit's pure-Swift hot paths
// (#73) with ordo-one's package-benchmark, on the macOS host. A package of
// its own, so neither the app nor `swift test` in BlauKit resolves the
// benchmark tooling.
//
//     make microbench          # run, print the results
//     make microbench-check    # regression gate against Thresholds/
//
// See docs/performance.md, "Micro-benchmarks".

import PackageDescription

let package = Package(
    name: "BlauKitBenchmarks",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../BlauKit"),
        // Formerly ordo-one/package-benchmark.
        .package(url: "https://github.com/ordo-one/benchmark.git", from: "1.36.4"),
    ],
    targets: [
        .executableTarget(
            name: "KitBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
                .product(name: "BlauCore", package: "BlauKit"),
                .product(name: "BlauTopics", package: "BlauKit"),
                .product(name: "BlauMemory", package: "BlauKit"),
            ],
            path: "Benchmarks/KitBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        )
    ],
    swiftLanguageModes: [.v6]
)
