import BlauCore
import Foundation
import Testing

@testable import BlauTelemetry

@Suite("Latency budget")
struct LatencyBudgetTests {
    // MARK: The budget

    @Test func theStandardBudgetIsTheOneInTheIssue() {
        let budget = LatencyBudget.standard
        #expect(budget.endOfUtterance == .init(p50Milliseconds: 800, expectedMinimumMilliseconds: 300))
        #expect(budget.voiceGate.p50Milliseconds == 100)
        #expect(budget.firstAudio.p50Milliseconds == 700)
        #expect(budget.firstBuffer.p50Milliseconds == 50)
        #expect(budget.total.p50Milliseconds == 1_500)
        #expect(
            LatencyHop.allCases.map { budget[$0].description } == [
                "300–800 ms", "≤ 100 ms", "≤ 700 ms", "≤ 50 ms", "≤ 1500 ms",
            ])
    }

    @Test func aMedianAtTheTargetIsWithinBudget() {
        let budget = LatencyBudget.standard
        #expect(budget.isWithinBudget(.total, p50Milliseconds: 1_500))
        #expect(!budget.isWithinBudget(.total, p50Milliseconds: 1_500.5))
        // Faster than the debounce's floor is not a failure.
        #expect(budget.isWithinBudget(.endOfUtterance, p50Milliseconds: 120))
        #expect(!budget.isWithinBudget(.voiceGate, p50Milliseconds: 101))
    }

    @Test func eachHopNamesItsInstrumentsInterval() {
        #expect(
            LatencyHop.allCases.map(\.interval) == [
                .asrEndOfUtterance, .voiceIDGate, .realtimeFirstAudio, .playbackFirstBuffer, nil,
            ])
        #expect(
            LatencyHop.allCases.map(\.shortTitle) == [
                "Speech → EOU", "Voice gate", "Commit → audio", "First buffer", "Speech → audio",
            ])
    }

    // MARK: Timelines and samples

    @Test func aFullTimelineGivesEveryHop() {
        let timeline = TurnLatencyTimeline(
            endOfSpeech: .seconds(10), endOfUtterance: .milliseconds(10_640), committed: .milliseconds(10_652),
            firstAudio: .milliseconds(11_250), firstBuffer: .milliseconds(11_291))
        #expect(timeline.duration(of: .endOfUtterance) == .milliseconds(640))
        #expect(timeline.duration(of: .voiceGate) == .milliseconds(12))
        #expect(timeline.duration(of: .firstAudio) == .milliseconds(598))
        #expect(timeline.duration(of: .firstBuffer) == .milliseconds(41))
        #expect(timeline.duration(of: .total) == .milliseconds(1_291))

        let sample = TurnLatencySample(turn: 3, recordedAt: Date(timeIntervalSince1970: 0), timeline: timeline)
        #expect(sample.endOfUtteranceMilliseconds.map { $0.rounded() } == 640)
        #expect(sample.voiceGateMilliseconds.map { $0.rounded() } == 12)
        #expect(sample.firstAudioMilliseconds.map { $0.rounded() } == 598)
        #expect(sample.firstBufferMilliseconds.map { $0.rounded() } == 41)
        #expect(sample.totalMilliseconds.map { $0.rounded() } == 1_291)
        #expect(
            sample.summary
                == "end of speech → EOU 640 · gate 12 · first audio 598 · first buffer 41 · total 1291 ms")
    }

    @Test func missingMomentsLeaveTheirHopsOut() {
        // No transcriber marks (Apple's fallback): only the hops from the
        // commit on, and no total.
        let timeline = TurnLatencyTimeline(
            committed: .seconds(5), firstAudio: .milliseconds(5_700), firstBuffer: nil)
        #expect(timeline.duration(of: .endOfUtterance) == nil)
        #expect(timeline.duration(of: .voiceGate) == nil)
        #expect(timeline.duration(of: .firstAudio) == .milliseconds(700))
        #expect(timeline.duration(of: .firstBuffer) == nil)
        #expect(timeline.duration(of: .total) == nil)
        let sample = TurnLatencySample(turn: 1, recordedAt: .now, timeline: timeline)
        #expect(sample.summary == "first audio 700 ms")
        #expect(TurnLatencySample(turn: 1, recordedAt: .now).summary == "no hops measured")
    }

    @Test func clocksThatDisagreeByATickNeverGiveANegativeHop() {
        let timeline = TurnLatencyTimeline(
            endOfSpeech: .milliseconds(1_001), endOfUtterance: .milliseconds(1_000), committed: .milliseconds(1_000))
        #expect(timeline.duration(of: .endOfUtterance) == .zero)
    }

    @Test func theAcousticTotalAddsTheHardwareLatency() {
        let hardware = AudioHardwareLatency(
            inputMilliseconds: 12, outputMilliseconds: 18.5, ioBufferMilliseconds: 10.7, sampleRate: 48_000,
            route: "builtInMic -> builtInSpeaker")
        #expect(hardware.roundTripMilliseconds == 30.5)
        let sample = TurnLatencySample(turn: 1, recordedAt: .now, totalMilliseconds: 1_200, hardware: hardware)
        #expect(sample.acousticTotalMilliseconds == 1_230.5)
        #expect(TurnLatencySample(turn: 1, recordedAt: .now, totalMilliseconds: 1_200).acousticTotalMilliseconds == nil)
    }

    // MARK: Marks

    @Test func marksAreTakenOnceByUtterance() {
        let marks = LatencyMarks()
        let id = UUID()
        let mark = LatencyMarks.Marks(endOfSpeech: .seconds(1), endOfUtterance: .milliseconds(1_640))
        marks.record(mark, for: id)
        #expect(marks.count == 1)
        #expect(marks.take(UUID()) == nil)
        #expect(marks.take(id) == mark)
        #expect(marks.take(id) == nil)
        #expect(marks.count == 0)
    }

    @Test func onlyTheNewestMarksAreKept() {
        let marks = LatencyMarks(capacity: 2)
        let ids = (0..<3).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            marks.record(.init(endOfSpeech: nil, endOfUtterance: .seconds(index)), for: id)
        }
        #expect(marks.count == 2)
        #expect(marks.take(ids[0]) == nil)
        #expect(marks.take(ids[1])?.endOfUtterance == .seconds(1))
        #expect(marks.take(ids[2])?.endOfUtterance == .seconds(2))
    }

    @Test func recordingAgainReplacesWithoutGrowing() {
        let marks = LatencyMarks(capacity: 2)
        let id = UUID()
        marks.record(.init(endOfSpeech: nil, endOfUtterance: .seconds(1)), for: id)
        marks.record(.init(endOfSpeech: nil, endOfUtterance: .seconds(2)), for: id)
        #expect(marks.count == 1)
        #expect(marks.take(id)?.endOfUtterance == .seconds(2))
    }

    // MARK: Tracker

    @Test func theTrackerKeepsTheNewestTurnsAndCountsAll() {
        let tracker = LatencyBudgetTracker(capacity: 3)
        for turn in 1...5 {
            tracker.record(TurnLatencySample(turn: turn, recordedAt: .now, totalMilliseconds: Double(turn * 100)))
        }
        #expect(tracker.samples.map(\.turn) == [3, 4, 5])
        #expect(tracker.totalRecorded == 5)
        tracker.reset()
        #expect(tracker.samples.isEmpty)
        #expect(tracker.totalRecorded == 0)
    }

    @Test func theTrackerReadsTheHardwareLatencyFromItsProvider() {
        let tracker = LatencyBudgetTracker()
        #expect(tracker.currentHardwareLatency() == nil)
        let hardware = AudioHardwareLatency(
            inputMilliseconds: 5, outputMilliseconds: 7, ioBufferMilliseconds: 10, sampleRate: 48_000, route: "a -> b")
        tracker.setHardwareLatencyProvider { hardware }
        #expect(tracker.currentHardwareLatency() == hardware)
        #expect(tracker.report(context: .init()).hardware == hardware)
        tracker.setHardwareLatencyProvider(nil)
        #expect(tracker.currentHardwareLatency() == nil)
    }
}

@Suite("Latency budget report")
struct LatencyBudgetReportTests {
    static let builtIn = AudioHardwareLatency(
        inputMilliseconds: 10, outputMilliseconds: 20, ioBufferMilliseconds: 10.7, sampleRate: 48_000,
        route: "builtInMic -> builtInSpeaker")
    static let airPods = AudioHardwareLatency(
        inputMilliseconds: 40, outputMilliseconds: 160, ioBufferMilliseconds: 10.7, sampleRate: 24_000,
        route: "bluetoothHFP -> bluetoothHFP")
    static let generatedAt = Date(timeIntervalSince1970: 1_791_547_200)  // 2026-10-09 12:00:00 UTC
    static let context = DiagnosticsExportContext(
        appVersion: "0.1.0", appBuild: "7", bundleIdentifier: "com.joeblau.blau",
        osVersion: "Version 26.1 (Build 23B85)", deviceModel: "iPhone16,1")

    /// Ten turns: totals 1100…2000 ms, EOU 600…780, gate 10…19, first
    /// audio 450…900, first buffer 40…49; the last two on AirPods.
    static func samples() -> [TurnLatencySample] {
        (0..<10).map { index in
            let i = Double(index)
            return TurnLatencySample(
                turn: index + 1, recordedAt: generatedAt.addingTimeInterval(-600 + i * 30),
                endOfUtteranceMilliseconds: 600 + i * 20, voiceGateMilliseconds: 10 + i,
                firstAudioMilliseconds: 450 + i * 50, firstBufferMilliseconds: 40 + i,
                totalMilliseconds: 1_100 + i * 100, hardware: index >= 8 ? airPods : builtIn)
        }
    }

    @Test func everyHopIsSummarizedAgainstItsTarget() throws {
        let report = LatencyBudgetReport(samples: Self.samples(), context: Self.context, generatedAt: Self.generatedAt)
        #expect(report.format == "com.joeblau.blau.latency.v1")
        #expect(report.turnCount == 10)
        #expect(report.hops.map(\.hop) == LatencyHop.allCases)

        let total = try #require(report.summary(for: .total))
        #expect(total.summary?.p50 == 1_550)
        #expect(total.summary?.p95 == 1_955)
        #expect(total.isWithinBudget == false)
        let gate = try #require(report.summary(for: .voiceGate))
        #expect(gate.summary?.p50 == 14.5)
        #expect(gate.isWithinBudget == true)
        #expect(report.summary(for: .firstAudio)?.summary?.p50 == 675)
        #expect(report.summary(for: .firstAudio)?.isWithinBudget == true)

        #expect(report.isWithinBudget == false)
        #expect(report.hopsOverBudget == [.total])
    }

    @Test func theAcousticTotalAndRoutesComeFromEachTurnsHardware() throws {
        let report = LatencyBudgetReport(samples: Self.samples(), context: Self.context, generatedAt: Self.generatedAt)
        // Eight turns at +30 ms, two at +200 ms.
        let acoustic = try #require(report.acousticTotal)
        #expect(acoustic.count == 10)
        #expect(acoustic.maximum == 2_200)
        #expect(acoustic.minimum == 1_130)
        #expect(report.routes == ["builtInMic -> builtInSpeaker", "bluetoothHFP -> bluetoothHFP"])
    }

    @Test func anEmptyReportHasNoVerdict() {
        let report = LatencyBudgetReport(samples: [], context: .init(), generatedAt: Self.generatedAt)
        #expect(report.isWithinBudget == nil)
        #expect(report.hops.allSatisfy { $0.summary == nil && $0.isWithinBudget == nil })
        #expect(report.acousticTotal == nil)
        #expect(report.markdownRow == "| – | – | – | – | 0 | – | – | – | – | – | – | – | 2026-10-09 |")
    }

    @Test func theTableRowMatchesTheDocsHeader() throws {
        let report = LatencyBudgetReport(samples: Self.samples(), context: Self.context, generatedAt: Self.generatedAt)
        #expect(
            report.markdownRow
                == "| 0.1.0 (7) | iPhone16,1 | 26.1 (23B85) | `builtInMic -> builtInSpeaker` | 10 | 690 / 771 | 15 / 19 | 675 / 878 | 45 / 49 | 1550 / 1955 | 1580 / 2155 | over: total | 2026-10-09 |"
        )
        let header = LatencyBudgetReport.markdownHeader.split(separator: "\n")
        let columns = { (line: Substring) in line.split(separator: "|", omittingEmptySubsequences: false).count }
        #expect(columns(header[0]) == columns(Substring(report.markdownRow)))

        // docs/performance.md records the releases under this exact header.
        let doc = try PipelineIntervalTests.performanceDoc()
        #expect(doc.contains(LatencyBudgetReport.markdownHeader))
    }

    @Test func aReportWithinBudgetSaysSo() {
        let fast = (0..<5).map {
            TurnLatencySample(
                turn: $0, recordedAt: Self.generatedAt, endOfUtteranceMilliseconds: 640, voiceGateMilliseconds: 8,
                firstAudioMilliseconds: 520, firstBufferMilliseconds: 42, totalMilliseconds: 1_210)
        }
        let report = LatencyBudgetReport(samples: fast, context: Self.context, generatedAt: Self.generatedAt)
        #expect(report.isWithinBudget == true)
        #expect(report.markdownRow.contains("| within |"))
    }

    @Test func theExportRoundTripsAndIsNamedByItsDate() throws {
        let report = LatencyBudgetReport(
            samples: Self.samples(), context: Self.context, hardware: Self.builtIn, generatedAt: Self.generatedAt)
        let data = try report.encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"format\" : \"com.joeblau.blau.latency.v1\""))
        #expect(json.contains("\"generatedAt\" : \"2026-10-09T12:00:00Z\""))
        #expect(try LatencyBudgetReport.decode(data) == report)

        #expect(LatencyBudgetReport.fileName(generatedAt: Self.generatedAt) == "Blau-Latency-20261009-120000.json")
        let folder = FileManager.default.temporaryDirectory.appending(path: "LatencyReport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try report.write(to: folder)
        #expect(file.lastPathComponent == "Blau-Latency-20261009-120000.json")
        #expect(try LatencyBudgetReport.decode(Data(contentsOf: file)) == report)
    }

    /// The budget table in docs/performance.md must state the same targets
    /// as the code.
    @Test func theDocsBudgetTableMatchesTheCode() throws {
        let doc = try PipelineIntervalTests.performanceDoc()
        let budget = LatencyBudget.standard
        for hop in LatencyHop.allCases {
            let row = doc.split(separator: "\n").first { $0.hasPrefix("| `\(hop.rawValue)`") }
            let cells = try #require(row, "No budget row for \(hop)").split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let target = budget[hop]
            let stated = cells[2].replacingOccurrences(of: "*", with: "")
            if let minimum = target.expectedMinimumMilliseconds {
                #expect(stated.hasPrefix("\(Int(minimum))–\(Int(target.p50Milliseconds)) ms"), "\(hop)")
            } else if target.p50Milliseconds >= 1_000 {
                #expect(stated == "≤ \(target.p50Milliseconds / 1_000) s", "\(hop)")
            } else {
                #expect(stated == "≤ \(Int(target.p50Milliseconds)) ms", "\(hop)")
            }
            #expect(cells[4] == hop.shortTitle, "\(hop)")
        }
    }
}

@Suite("Latency budget in the HUD")
struct LatencyBudgetHUDTests {
    static func stats(p50: Double, p95: Double, count: Int = 12) -> LatencyStats {
        LatencyStats(last: p50, p50: p50, p95: p95, mean: p50, maximum: p95, windowCount: count, totalCount: count)
    }

    @Test func eachHopIsCheckedAgainstItsTarget() {
        let readings = PipelineReadings(latencyHops: [
            .endOfUtterance: Self.stats(p50: 640, p95: 780),
            .voiceGate: Self.stats(p50: 120, p95: 160),
            .firstAudio: Self.stats(p50: 1_100, p95: 1_400),
            .firstBuffer: Self.stats(p50: 42, p95: 60),
            .total: Self.stats(p50: 1_420, p95: 1_900),
        ])
        let readout = PerformanceHUDReadout(PerformanceHUDSnapshot(pipeline: readings))
        let section = readout.sections.first { $0.title == "Latency budget" }
        #expect(section?.rows.map(\.label) == LatencyHop.allCases.map(\.shortTitle))
        #expect(readout.row("Speech → EOU") == .init(label: "Speech → EOU", value: "p50 640 · p95 780 / 800 ms (n=12)"))
        #expect(readout.row("Voice gate")?.level == .warning)
        #expect(readout.row("Commit → audio")?.level == .critical, "Over by more than half")
        #expect(readout.row("First buffer")?.level == .normal)
        #expect(readout.compact.last == .init(label: "Speech → audio", value: "p50 1420 · p95 1900 / 1500 ms"))
        #expect(readout.level == .critical)
    }

    @Test func noTurnsYetShowPlaceholders() {
        let readout = PerformanceHUDReadout(PerformanceHUDSnapshot())
        for hop in LatencyHop.allCases {
            #expect(readout.row(hop.shortTitle)?.value == "–")
        }
        #expect(readout.compact.last?.value == "–")
    }
}
