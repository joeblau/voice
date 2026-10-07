import Foundation

/// Words and names the user is likely to say that a speech recognizer
/// wouldn't guess: the people, companies, products and projects Blau has
/// learned about. Speech recognizers that accept a vocabulary (Apple's
/// `SpeechTranscriber` takes them as `AnalysisContext.contextualStrings`)
/// bias recognition toward them.
///
/// It lives in BlauCore so memory (BlauPersistence's `MemoryEntityVocabulary`
/// today, BlauMemory later) can provide it and BlauTranscription can consume
/// it without either importing the other.
public protocol RecognitionVocabularySource: Sendable {
    /// The terms, most important first. Callers trim the list with
    /// `RecognitionVocabulary.normalized(_:limit:)`.
    func recognitionVocabulary() async -> [String]
}

/// A fixed list. For tests, previews and as a stand-in until memory provides
/// one.
public struct StaticRecognitionVocabulary: RecognitionVocabularySource {
    public let terms: [String]

    public init(_ terms: [String]) {
        self.terms = terms
    }

    public func recognitionVocabulary() async -> [String] { terms }
}

/// Helpers for preparing a vocabulary for a recognizer.
public enum RecognitionVocabulary {
    /// The most terms handed to a recognizer. Apple recommends keeping
    /// contextual strings to about a hundred phrases; more slows the
    /// recognizer down without helping.
    public static let defaultLimit = 100

    /// The longest single term kept, in characters. A vocabulary entry is a
    /// name or a short phrase, not a sentence.
    public static let maximumTermLength = 64

    /// `terms` trimmed, with blank, overlong and repeated entries (ignoring
    /// case and diacritics) dropped, in order, at most `limit` of them.
    public static func normalized(_ terms: [String], limit: Int = defaultLimit) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for term in terms {
            guard result.count < limit else { break }
            let trimmed = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !trimmed.isEmpty, trimmed.count <= maximumTermLength else { continue }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
