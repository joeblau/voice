import BlauTelemetry
import Foundation
import Synchronization
import Testing

@Suite("Benchmark device and memory")
struct BenchmarkEnvironmentTests {
    @Test func currentDeviceIsThisMac() {
        let device = BenchmarkDevice.current
        // `Mac15,8`, `MacBookPro18,3`, `iMac21,1`, or `VirtualMac2,1` on a
        // virtualized CI runner.
        #expect(device.modelIdentifier.contains("Mac"), "\(device.modelIdentifier)")
        #expect(device.operatingSystem.hasPrefix("macOS "))
        #expect(device.chip?.isEmpty == false)
        #expect(device.physicalMemoryBytes > 0)
        #expect(device.activeProcessorCount > 0)
        #expect(!device.isSimulator)
    }

    @Test func knowsTheTargetIPhones() {
        #expect(BenchmarkDevice.lookup("iPhone16,1")?.chip == "A17 Pro")
        #expect(BenchmarkDevice.lookup("iPhone17,3")?.name == "iPhone 16")
        #expect(BenchmarkDevice.lookup("iPhone18,1")?.chip == "A19 Pro")
        #expect(BenchmarkDevice.lookup("iPhone99,9") == nil)
    }

    @Test func displayNameFallsBackToTheIdentifier() {
        #expect(BenchmarkDevice.fixture(identifier: "iPhone17,1").displayName == "iPhone 16 Pro (A18 Pro)")
        #expect(BenchmarkDevice.fixture(identifier: "iPhone99,9").displayName == "iPhone99,9")
        #expect(
            BenchmarkDevice.fixture(identifier: "iPhone17,3", simulator: true).displayName
                == "iPhone 16 (A18), Simulator")
    }

    @Test func thermalStatesAreOrdered() {
        #expect(ThermalState.nominal < .fair)
        #expect(ThermalState.serious < .critical)
        #expect(ThermalState(ProcessInfo.ThermalState.serious) == .serious)
    }

    @Test func processProbeReadsThisProcess() throws {
        let snapshot = try #require(ProcessMemoryProbe().snapshot())
        #expect(snapshot.physicalFootprint > 1_048_576)
        if let peak = snapshot.peakPhysicalFootprint {
            #expect(peak >= snapshot.physicalFootprint)
        }
        // os_proc_available_memory() is iOS only.
        #expect(snapshot.available == nil)
    }

    @Test func watermarkTracksTheHighestSample() {
        let probe = SequenceMemoryProbe([
            MemorySnapshot(physicalFootprint: 100, peakPhysicalFootprint: nil, neural: 10, available: nil),
            MemorySnapshot(physicalFootprint: 400, peakPhysicalFootprint: nil, neural: 60, available: nil),
            MemorySnapshot(physicalFootprint: 250, peakPhysicalFootprint: nil, neural: 30, available: nil),
        ])
        var watermark = MemoryWatermark(probe: probe)
        watermark.sample()
        watermark.sample()
        #expect(watermark.baseline?.physicalFootprint == 100)
        #expect(watermark.latest?.physicalFootprint == 250)
        #expect(watermark.footprintGrowth == 300)
        #expect(watermark.neuralGrowth == 50)
    }

    @Test func watermarkNeverReportsNegativeGrowth() {
        let probe = SequenceMemoryProbe([
            MemorySnapshot(physicalFootprint: 500, peakPhysicalFootprint: nil, neural: nil, available: nil),
            MemorySnapshot(physicalFootprint: 300, peakPhysicalFootprint: nil, neural: nil, available: nil),
        ])
        var watermark = MemoryWatermark(probe: probe)
        watermark.sample()
        #expect(watermark.footprintGrowth == 0)
        #expect(watermark.neuralGrowth == nil)
    }
}

/// Returns the given readings in order, then repeats the last.
final class SequenceMemoryProbe: MemoryProbe {
    private let readings: Mutex<[MemorySnapshot]>

    init(_ readings: [MemorySnapshot]) {
        self.readings = Mutex(readings)
    }

    func snapshot() -> MemorySnapshot? {
        readings.withLock { readings in readings.count > 1 ? readings.removeFirst() : readings.first }
    }
}
