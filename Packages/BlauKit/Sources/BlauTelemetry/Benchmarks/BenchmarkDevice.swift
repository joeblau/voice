import Darwin
import Foundation

/// The hardware and OS a benchmark ran on.
///
/// The raw `modelIdentifier` (`iPhone17,1`, `Mac15,6`) is always recorded.
/// `marketingName` and `chip` come from a lookup table of the iPhones Blau
/// targets and are `nil` for anything the table doesn't know.
public struct BenchmarkDevice: Codable, Hashable, Sendable {
    /// `hw.machine` on iOS (the simulated model on the simulator),
    /// `hw.model` on macOS.
    public let modelIdentifier: String
    public let marketingName: String?
    /// For example `A18 Pro`, or the CPU brand string on a Mac.
    public let chip: String?
    /// For example `iOS 27.2 (Build 24C5054e)`.
    public let operatingSystem: String
    public let physicalMemoryBytes: UInt64
    public let activeProcessorCount: Int
    public let isSimulator: Bool

    public init(
        modelIdentifier: String,
        marketingName: String?,
        chip: String?,
        operatingSystem: String,
        physicalMemoryBytes: UInt64,
        activeProcessorCount: Int,
        isSimulator: Bool
    ) {
        self.modelIdentifier = modelIdentifier
        self.marketingName = marketingName
        self.chip = chip
        self.operatingSystem = operatingSystem
        self.physicalMemoryBytes = physicalMemoryBytes
        self.activeProcessorCount = activeProcessorCount
        self.isSimulator = isSimulator
    }

    /// The device this process is running on.
    public static var current: BenchmarkDevice {
        let processInfo = ProcessInfo.processInfo
        let identifier = currentModelIdentifier()
        let known = knownModels[identifier]
        #if targetEnvironment(simulator)
            let isSimulator = true
            let platform = "iOS Simulator"
            let chip = known?.chip
        #elseif os(macOS)
            let isSimulator = false
            let platform = "macOS"
            let chip = known?.chip ?? sysctlString("machdep.cpu.brand_string")
        #else
            let isSimulator = false
            let platform = "iOS"
            let chip = known?.chip
        #endif
        let version = processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
        return BenchmarkDevice(
            modelIdentifier: identifier,
            marketingName: known?.name,
            chip: chip,
            operatingSystem: "\(platform) \(version)",
            physicalMemoryBytes: processInfo.physicalMemory,
            activeProcessorCount: processInfo.activeProcessorCount,
            isSimulator: isSimulator
        )
    }

    /// A short label for tables: `iPhone 16 Pro (A18 Pro)`, or the raw
    /// identifier when the model is unknown.
    public var displayName: String {
        let name = marketingName ?? modelIdentifier
        let label = chip.map { "\(name) (\($0))" } ?? name
        return isSimulator ? "\(label), Simulator" : label
    }

    // MARK: Model table

    /// The marketing name and chip for a model identifier, if the table
    /// knows it.
    public static func lookup(_ modelIdentifier: String) -> (name: String, chip: String)? {
        knownModels[modelIdentifier].map { ($0.name, $0.chip) }
    }

    struct KnownModel: Hashable, Sendable {
        let name: String
        let chip: String
    }

    /// iPhones from the A16 on (Apple Intelligence needs an A17 Pro or later).
    static let knownModels: [String: KnownModel] = [
        "iPhone15,2": KnownModel(name: "iPhone 14 Pro", chip: "A16 Bionic"),
        "iPhone15,3": KnownModel(name: "iPhone 14 Pro Max", chip: "A16 Bionic"),
        "iPhone15,4": KnownModel(name: "iPhone 15", chip: "A16 Bionic"),
        "iPhone15,5": KnownModel(name: "iPhone 15 Plus", chip: "A16 Bionic"),
        "iPhone16,1": KnownModel(name: "iPhone 15 Pro", chip: "A17 Pro"),
        "iPhone16,2": KnownModel(name: "iPhone 15 Pro Max", chip: "A17 Pro"),
        "iPhone17,1": KnownModel(name: "iPhone 16 Pro", chip: "A18 Pro"),
        "iPhone17,2": KnownModel(name: "iPhone 16 Pro Max", chip: "A18 Pro"),
        "iPhone17,3": KnownModel(name: "iPhone 16", chip: "A18"),
        "iPhone17,4": KnownModel(name: "iPhone 16 Plus", chip: "A18"),
        "iPhone17,5": KnownModel(name: "iPhone 16e", chip: "A18"),
        "iPhone18,1": KnownModel(name: "iPhone 17 Pro", chip: "A19 Pro"),
        "iPhone18,2": KnownModel(name: "iPhone 17 Pro Max", chip: "A19 Pro"),
        "iPhone18,3": KnownModel(name: "iPhone 17", chip: "A19"),
        "iPhone18,4": KnownModel(name: "iPhone Air", chip: "A19 Pro"),
    ]

    private static func currentModelIdentifier() -> String {
        #if targetEnvironment(simulator)
            if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
                return simulated
            }
        #endif
        #if os(macOS)
            return sysctlString("hw.model") ?? "Mac"
        #else
            return sysctlString("hw.machine") ?? "unknown"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// `ProcessInfo.ThermalState`, recorded with every result: a hot device
/// throttles and its numbers are not comparable.
public enum ThermalState: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    /// The current thermal state of this device.
    public static var current: ThermalState { ThermalState(ProcessInfo.processInfo.thermalState) }

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
