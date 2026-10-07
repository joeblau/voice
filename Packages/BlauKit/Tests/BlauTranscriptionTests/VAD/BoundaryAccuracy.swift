import BlauCore
import Testing

@testable import BlauTranscription

/// Compares reported segments with a fixture's labels.
struct BoundaryAccuracy: CustomStringConvertible {
    /// The acceptance criterion: ±100 ms.
    static let tolerance: Int64 = 1_600

    let fixture: String
    let labels: [Range<Int64>]
    /// Reported segments with forced splits joined back together (a split
    /// continues the same speech, so it's compared with one label).
    let utterances: [Range<Int64>]

    init(fixture: String, labels: [Range<Int64>], segments: [SpeechSegment]) {
        self.fixture = fixture
        self.labels = labels
        var joined: [Range<Int64>] = []
        for segment in segments {
            if segment.isContinuation, let last = joined.last {
                joined[joined.count - 1] = last.lowerBound..<segment.sampleRange.upperBound
            } else {
                joined.append(segment.sampleRange)
            }
        }
        utterances = joined
    }

    /// Start and end errors in samples (reported − label), when the counts
    /// match.
    var errors: [(start: Int64, end: Int64)]? {
        guard labels.count == utterances.count else { return nil }
        return zip(labels, utterances).map { label, reported in
            (reported.lowerBound - label.lowerBound, reported.upperBound - label.upperBound)
        }
    }

    var worstError: Int64? {
        errors?.map { max(abs($0.start), abs($0.end)) }.max()
    }

    var isWithinTolerance: Bool {
        (worstError ?? .max) <= Self.tolerance
    }

    var description: String {
        func ms(_ samples: Int64) -> String { "\(samples / 16) ms" }
        let labelText = labels.map { "\(ms($0.lowerBound))–\(ms($0.upperBound))" }.joined(separator: ", ")
        let reportedText = utterances.map { "\(ms($0.lowerBound))–\(ms($0.upperBound))" }.joined(separator: ", ")
        let errorText =
            errors.map { $0.map { "\(ms($0.start))/\(ms($0.end))" }.joined(separator: ", ") } ?? "count mismatch"
        return "\(fixture): labels [\(labelText)] reported [\(reportedText)] errors start/end [\(errorText)]"
    }
}
