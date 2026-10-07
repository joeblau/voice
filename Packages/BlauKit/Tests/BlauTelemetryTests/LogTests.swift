import BlauTelemetry
import Testing
import os

@Suite("Log categories")
struct LogTests {
    @Test func usesTheAppSubsystem() {
        #expect(Log.subsystem == "com.joeblau.blau")
    }

    @Test func coversEveryArea() {
        #expect(
            LogCategory.allCases.map(\.rawValue) == [
                "audio", "asr", "voiceid", "realtime", "topics", "memory", "data", "ui", "perf",
            ]
        )
    }

    @Test func categoryStringsAreUniqueLowercaseIdentifiers() {
        let raw = LogCategory.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count)
        for category in raw {
            #expect(category.allSatisfy { $0.isLowercase && $0.isLetter }, "\(category)")
        }
    }

    /// Exercises each static logger, including the privacy annotations the
    /// docs ask for. Logging must never crash, whether or not anything is
    /// collecting.
    @Test func everyLoggerAcceptsMessages() {
        let loggers: [Logger] = [
            Log.audio, Log.asr, Log.voiceID, Log.realtime, Log.topics, Log.memory, Log.data, Log.ui,
            Log.performance,
        ]
        let transcript = "a private sentence"
        for (index, logger) in loggers.enumerated() {
            logger.debug("BlauTelemetry test message \(index, privacy: .public)")
            logger.info("Transcript: \(transcript, privacy: .private)")
            logger.notice("Correlated: \(transcript, privacy: .private(mask: .hash))")
        }
        for category in LogCategory.allCases {
            Log.logger(for: category).debug("Runtime category \(category.rawValue, privacy: .public)")
        }
        Logger.disabled.error("Never recorded \(transcript, privacy: .private)")
    }
}
