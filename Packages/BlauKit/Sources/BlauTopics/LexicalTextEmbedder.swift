import BlauCore
import Foundation

/// A deterministic bag-of-words embedder: content words, lightly stemmed and
/// hashed into a fixed number of signed buckets, with sublinear term
/// frequency, scaled to unit length.
///
/// This is the lexical-cohesion signal the original TextTiling algorithm
/// used. It needs no model, runs in microseconds and gives the same vector on
/// every device and OS version, which makes it the reference embedder for the
/// segmentation tests and the fallback when contextual embedding assets
/// aren't on the device yet. It knows nothing about synonyms; the contextual
/// and EmbeddingGemma embedders do.
public struct LexicalTextEmbedder: TextEmbedder {
    public let dimension: Int

    public var modelIdentifier: String { "lexical-hash-\(dimension)-v1" }

    /// - Precondition: `dimension > 0`.
    public init(dimension: Int = 1024) {
        precondition(dimension > 0, "LexicalTextEmbedder needs a positive dimension")
        self.dimension = dimension
    }

    public func embed(_ text: String) async throws -> [Float] {
        vector(for: text)
    }

    /// The embedding, synchronously.
    public func vector(for text: String) -> [Float] {
        var counts: [String: Int] = [:]
        for term in Self.terms(in: text) {
            counts[term, default: 0] += 1
        }
        var vector = [Float](repeating: 0, count: dimension)
        // Sorted so floating-point accumulation order, and therefore the
        // exact vector, doesn't depend on dictionary order.
        for (term, count) in counts.sorted(by: { $0.key < $1.key }) {
            let hash = Self.fnv1a(term)
            let bucket = Int(hash % UInt64(dimension))
            let sign: Float = (hash >> 63) == 0 ? 1 : -1
            vector[bucket] += sign * (1 + Float(log(Double(count))))
        }
        return VectorMath.normalized(vector)
    }

    /// The stemmed content words of `text`, in order.
    static func terms(in text: String) -> [String] {
        var terms: [String] = []
        var word = ""
        func flush() {
            defer { word.removeAll(keepingCapacity: true) }
            guard word.count >= 3, !stopWords.contains(word) else { return }
            let stemmed = stem(word)
            if stemmed.count >= 3, !stopWords.contains(stemmed) {
                terms.append(stemmed)
            }
        }
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if character == "'" || character == "\u{2019}" {
                // "don't" -> "dont", "gear's" -> "gears"
                continue
            } else {
                flush()
            }
        }
        flush()
        return terms
    }

    /// A light suffix stripper (a small subset of Porter's rules), enough to
    /// join "bake", "baking", "baked" and "bakes".
    static func stem(_ word: String) -> String {
        var stem = word
        func drop(_ suffix: String, minimumLength: Int, replacement: String = "") -> Bool {
            guard stem.count >= minimumLength, stem.hasSuffix(suffix) else { return false }
            stem.removeLast(suffix.count)
            stem += replacement
            return true
        }
        let keepsFinalS = stem.hasSuffix("ss") || stem.hasSuffix("us") || stem.hasSuffix("is")
        // Plurals, then verb and adverb endings; the first rule that applies
        // in each group wins.
        _ =
            drop("sses", minimumLength: 6, replacement: "ss")
            || drop("ies", minimumLength: 5, replacement: "y")
            || (!keepsFinalS && drop("s", minimumLength: 4))
        _ = drop("ing", minimumLength: 6) || drop("ed", minimumLength: 5) || drop("ly", minimumLength: 5)
        if stem.count > 3, stem.hasSuffix("e") {
            stem.removeLast()
        }
        return stem
    }

    /// 64-bit FNV-1a over the UTF-8 bytes. Unlike `Hasher`, it is the same
    /// in every process.
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// English function words and conversational filler that say nothing
    /// about the topic. Apostrophes are already stripped ("dont").
    static let stopWords: Set<String> = [
        "about", "above", "actually", "after", "again", "against", "ago", "ahead", "all", "almost", "along",
        "already", "also", "although", "always", "and", "another", "any", "anyone", "anything", "anyway",
        "are", "arent", "around", "ask", "asked", "asking", "away", "back", "bad", "basically", "because",
        "been", "before", "being", "below", "best", "better", "between", "big", "bit", "both", "but", "can",
        "cannot", "cant", "certainly", "come", "comes", "coming", "could", "couldnt", "day", "definitely",
        "did", "didnt", "different", "does", "doesnt", "doing", "done", "dont", "down", "during", "each",
        "either", "else", "enough", "even", "ever", "every", "everyone", "everything", "exactly", "fair",
        "feel", "few", "fine", "first", "for", "from", "further", "get", "gets", "getting", "give", "glad",
        "goes", "going", "gonna", "good", "got", "gotten", "great", "guess", "had", "happy", "has", "hasnt",
        "have", "havent", "having", "help", "helpful", "her", "here", "hers", "herself", "hey", "him",
        "himself", "his", "honestly", "how", "however", "idea", "ill", "im", "into", "isnt", "its", "itself",
        "ive", "just", "keep", "kind", "know", "last", "later", "least", "less", "let", "lets", "like",
        "likely", "little", "long", "look", "looking", "lot", "lots", "made", "main", "make", "makes",
        "making", "many", "may", "maybe", "mean", "means", "might", "mine", "more", "most", "much", "must",
        "myself", "need", "needs", "never", "new", "next", "nice", "nope", "not", "nothing", "now", "off",
        "okay", "once", "one", "ones", "only", "onto", "other", "others", "our", "ours", "ourselves", "out",
        "over", "own", "part", "people", "perfect", "perhaps", "point", "pretty", "probably", "put", "question",
        "quite", "rather", "really", "right", "said", "same", "say", "saying", "says", "see", "seem", "seems",
        "she", "should", "shouldnt", "since", "small", "some", "someone", "something", "sometimes", "somewhat",
        "sort", "sound", "sounds", "start", "still", "such", "sure", "take", "talk", "talking", "tell",
        "than", "thank", "thanks", "that", "thats", "the", "their", "theirs", "them", "themselves", "then",
        "there", "theres", "these", "they", "theyre", "thing", "things", "think", "thinking", "this", "those",
        "though", "thought", "through", "time", "times", "today", "together", "too", "totally", "toward",
        "towards", "true", "try", "trying", "two", "under", "until", "upon", "use", "used", "using", "usually",
        "very", "want", "wanted", "wants", "was", "wasnt", "way", "ways", "well", "went", "were", "werent",
        "what", "whats", "when", "where", "whether", "which", "while", "who", "whole", "whom", "whose", "why",
        "will", "with", "within", "without", "wonder", "wont", "work", "works", "would", "wouldnt", "wow",
        "yeah", "yes", "yet", "you", "youd", "youll", "your", "youre", "yours", "yourself", "yourselves",
        "youve",
    ]
}
