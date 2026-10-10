import Darwin
import Foundation

/// The process's memory at one moment, in bytes.
///
/// `physicalFootprint` is the number jetsam and Xcode's memory gauge use, so
/// it is the one to budget against. Core ML keeps compiled Neural Engine
/// programs and their buffers partly outside the process (in the ANE
/// daemon), so the footprint alone undercounts a model on the Neural
/// Engine; the kernel's neural ledgers (`neural`) cover the part it
/// attributes to this process.
public struct MemorySnapshot: Codable, Hashable, Sendable {
    /// Current physical footprint (`task_vm_info.phys_footprint`).
    public let physicalFootprint: UInt64
    /// Highest footprint since the process started
    /// (`ledger_phys_footprint_peak`), when the kernel reports it.
    public let peakPhysicalFootprint: UInt64?
    /// Memory tagged as neural (Neural Engine) and attributed to this
    /// process, counted and uncounted toward the footprint, when reported.
    public let neural: UInt64?
    /// Bytes left before the process hits its memory limit
    /// (`os_proc_available_memory()`), iOS only.
    public let available: UInt64?

    public init(physicalFootprint: UInt64, peakPhysicalFootprint: UInt64?, neural: UInt64?, available: UInt64?) {
        self.physicalFootprint = physicalFootprint
        self.peakPhysicalFootprint = peakPhysicalFootprint
        self.neural = neural
        self.available = available
    }
}

/// Reads the process's memory. Benchmarks take one so tests can script the
/// readings.
public protocol MemoryProbe: Sendable {
    /// The current reading, or `nil` if the platform refused to report it.
    func snapshot() -> MemorySnapshot?
}

/// Reads this process's memory from the kernel (`task_info(TASK_VM_INFO)`).
public struct ProcessMemoryProbe: MemoryProbe {
    public init() {}

    public func snapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        let capacity = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        var count = capacity
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(capacity)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        /// Whether the kernel filled in the field at `keyPath` (older
        /// kernels return a shorter structure).
        func reported<Value>(_ keyPath: KeyPath<task_vm_info_data_t, Value>) -> Bool {
            guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: keyPath) else { return false }
            let end = offset + MemoryLayout<Value>.size
            return end <= Int(count) * MemoryLayout<natural_t>.size
        }

        let peak: UInt64? =
            reported(\.ledger_phys_footprint_peak) ? UInt64(clamping: info.ledger_phys_footprint_peak) : nil
        let neural: UInt64? =
            reported(\.ledger_tag_neural_nofootprint)
            ? UInt64(clamping: info.ledger_tag_neural_footprint)
                + UInt64(clamping: info.ledger_tag_neural_nofootprint)
            : nil

        return MemorySnapshot(
            physicalFootprint: UInt64(info.phys_footprint),
            peakPhysicalFootprint: peak,
            neural: neural,
            available: Self.availableBytes()
        )
    }

    private static func availableBytes() -> UInt64? {
        #if os(iOS)
            let bytes = os_proc_available_memory()
            return bytes > 0 ? UInt64(bytes) : nil
        #else
            return nil
        #endif
    }
}

/// The malloc heap at one moment, summed over every zone
/// (`malloc_zone_statistics`), in bytes.
///
/// Next to the footprint it tells live memory from memory the allocator
/// keeps: a footprint that climbs while `inUse` stays flat is freed memory
/// the allocator hasn't given back (fragmentation), not something the app
/// still holds.
public struct HeapUsage: Codable, Hashable, Sendable {
    /// Bytes in live allocations.
    public let inUse: UInt64
    /// Bytes the zones have reserved from the system (address space, not
    /// all of it resident).
    public let reserved: UInt64

    public init(inUse: UInt64, reserved: UInt64) {
        self.inUse = inUse
        self.reserved = reserved
    }

    /// This process's heap now.
    public static func current() -> HeapUsage {
        var statistics = malloc_statistics_t()
        // A nil zone sums every registered zone.
        malloc_zone_statistics(nil, &statistics)
        // (`max_size_in_use` isn't kept by the default zones: it reads 0.)
        return HeapUsage(inUse: UInt64(statistics.size_in_use), reserved: UInt64(statistics.size_allocated))
    }
}

/// Tracks the baseline and highest footprint seen while a benchmark runs.
///
/// Call `sample()` at points where memory is likely to peak (after loading,
/// every few chunks). The peak is the highest *sampled* footprint, so it is a
/// lower bound on the true peak between samples.
public struct MemoryWatermark: Sendable {
    public let baseline: MemorySnapshot?
    public private(set) var latest: MemorySnapshot?
    public private(set) var highestFootprint: UInt64?
    public private(set) var highestNeural: UInt64?
    private let probe: any MemoryProbe

    public init(probe: any MemoryProbe) {
        self.probe = probe
        baseline = probe.snapshot()
        latest = baseline
        highestFootprint = baseline?.physicalFootprint
        highestNeural = baseline?.neural
    }

    /// Takes a reading and updates the highs.
    @discardableResult
    public mutating func sample() -> MemorySnapshot? {
        guard let snapshot = probe.snapshot() else { return nil }
        latest = snapshot
        highestFootprint = max(highestFootprint ?? 0, snapshot.physicalFootprint)
        if let neural = snapshot.neural {
            highestNeural = max(highestNeural ?? 0, neural)
        }
        return snapshot
    }

    /// Highest sampled footprint above the baseline, in bytes (`0` if it
    /// never rose).
    public var footprintGrowth: UInt64? {
        guard let baseline, let highestFootprint else { return nil }
        return highestFootprint > baseline.physicalFootprint ? highestFootprint - baseline.physicalFootprint : 0
    }

    /// Highest sampled neural memory above the baseline, in bytes.
    public var neuralGrowth: UInt64? {
        guard let baselineNeural = baseline?.neural, let highestNeural else { return nil }
        return highestNeural > baselineNeural ? highestNeural - baselineNeural : 0
    }
}

extension UInt64 {
    /// The value in megabytes (2^20 bytes).
    public var megabytes: Double { Double(self) / 1_048_576 }
}
