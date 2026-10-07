// swift-tools-version: 6.2
//
// BlauKit: Blau's business logic, one library per subsystem. The app target
// (`Blau/`) links every library and only adds SwiftUI views and the
// composition root. See docs/architecture.md for the dependency graph.
//
// Run the tests on the macOS host with `swift test` (or `make test-kit` from
// the repo root).

import PackageDescription

// MARK: - Module graph

/// One BlauKit module. Each case becomes a library product, a source target in
/// `Sources/<name>` and a Swift Testing target in `Tests/<name>Tests`.
///
/// Dependencies point strictly down the layers below, so the graph cannot
/// form a cycle and sibling subsystems stay independent:
///
///     layer 0  BlauCore
///     layer 1  BlauTelemetry
///     layer 2  BlauAudio, BlauPersistence
///     layer 3  BlauTranscription, BlauVoiceID
///     layer 4  BlauRealtime, BlauTopics, BlauMemory
///
/// Modules in the same layer never import each other. When two of them must
/// cooperate (for example Realtime calling Memory's tools), a lower module
/// defines a protocol and the app's composition root wires the
/// implementation in. The manifest refuses to load if a dependency breaks
/// this rule (see `validateLayering()`).
enum KitModule: String, CaseIterable {
    case core = "BlauCore"
    case telemetry = "BlauTelemetry"
    case audio = "BlauAudio"
    case persistence = "BlauPersistence"
    case transcription = "BlauTranscription"
    case voiceID = "BlauVoiceID"
    case realtime = "BlauRealtime"
    case topics = "BlauTopics"
    case memory = "BlauMemory"

    var layer: Int {
        switch self {
        case .core: 0
        case .telemetry: 1
        case .audio, .persistence: 2
        case .transcription, .voiceID: 3
        case .realtime, .topics, .memory: 4
        }
    }

    /// BlauKit modules this module imports. Add to these lists as subsystems
    /// grow; anything in a strictly lower layer is allowed.
    var dependencies: [KitModule] {
        switch self {
        case .core: []
        case .telemetry: [.core]
        case .audio, .persistence: [.core, .telemetry]
        case .transcription, .voiceID: [.core, .telemetry, .audio]
        case .realtime: [.core, .telemetry, .audio]
        case .topics, .memory: [.core, .telemetry, .persistence]
        }
    }

    /// Third-party products this module links.
    var externalDependencies: [Target.Dependency] {
        switch self {
        case .transcription, .voiceID:
            // Silero VAD, Parakeet ASR and WeSpeaker embeddings (CoreML).
            [.product(name: "FluidAudio", package: "FluidAudio")]
        default:
            []
        }
    }

    /// Swift 6 language mode (set on the package) already turns on complete
    /// strict concurrency checking. `MemberImportVisibility` additionally
    /// requires each file to import the modules whose members it uses, so a
    /// transitive import can't hide a missing dependency edge.
    var swiftSettings: [SwiftSetting] {
        [.enableUpcomingFeature("MemberImportVisibility")]
    }

    var target: Target {
        .target(
            name: rawValue,
            dependencies: dependencies.map { .target(name: $0.rawValue) } + externalDependencies,
            swiftSettings: swiftSettings
        )
    }

    /// Resources bundled with the module's test target.
    var testResources: [Resource] {
        switch self {
        case .realtime:
            // Recorded and hand-written realtime sessions (JSON Lines).
            [.copy("Fixtures")]
        default:
            []
        }
    }

    var testTarget: Target {
        .testTarget(
            name: "\(rawValue)Tests",
            dependencies: [.target(name: rawValue)],
            resources: testResources,
            swiftSettings: swiftSettings
        )
    }

    var product: Product {
        .library(name: rawValue, targets: [rawValue])
    }
}

/// Stops manifest evaluation (and therefore every build) when a module
/// depends on its own layer or a layer above it.
func validateLayering() {
    for module in KitModule.allCases {
        for dependency in module.dependencies where dependency.layer >= module.layer {
            fatalError(
                """
                BlauKit layering violation: \(module.rawValue) (layer \(module.layer)) \
                must not depend on \(dependency.rawValue) (layer \(dependency.layer)). \
                Modules may only depend on strictly lower layers; see docs/architecture.md.
                """
            )
        }
    }
}

validateLayering()

// MARK: - Package

let package = Package(
    name: "BlauKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: KitModule.allCases.map(\.product),
    dependencies: [
        // Third-party pins live here. Add new ones only in the issue that needs them.
        //
        // FluidAudio: Silero VAD, Parakeet ASR and WeSpeaker embeddings. Its
        // default `NemoTextProcessing` trait links a prebuilt Rust text
        // normalizer (~8 MB per slice) that only its TTS frontends use; Blau
        // gets speech from Grok, so it opts out with `traits: []`.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5", traits: [])
    ],
    targets: KitModule.allCases.map(\.target) + KitModule.allCases.map(\.testTarget),
    swiftLanguageModes: [.v6]
)
