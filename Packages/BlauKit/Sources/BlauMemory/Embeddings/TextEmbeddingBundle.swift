import Foundation

/// An installed text-embedding model: the directory
/// `scripts/embeddings/convert_coreml.py` prepares for hosting and
/// `ModelManager` downloads (`ModelID.textEmbedding`).
///
/// ```
/// <directory>/
///   blau-embedding.json                  what is below, prompts and widths
///   EmbeddingGemma300M.mlmodelc/         inputs_embeds + attention_mask → embedding
///   EmbeddingGemma300M.token-embeddings.i8 (or .f16)
///   tokenizer.json
///   NOTICE / LICENSE
/// ```
public struct TextEmbeddingBundle: Hashable, Sendable {
    /// `blau-embedding.json`.
    public struct Metadata: Codable, Hashable, Sendable {
        public struct Source: Codable, Hashable, Sendable {
            public var repo: String
            public var revision: String
            public var license: String?

            public init(repo: String, revision: String, license: String? = nil) {
                self.repo = repo
                self.revision = revision
                self.license = license
            }
        }

        public struct TokenEmbeddings: Codable, Hashable, Sendable {
            public var file: String
            public var dtype: String
            public var vocabularySize: Int
            public var width: Int

            public init(file: String, dtype: String, vocabularySize: Int, width: Int) {
                self.file = file
                self.dtype = dtype
                self.vocabularySize = vocabularySize
                self.width = width
            }
        }

        /// `TextEmbeddingModelSpec.id` of the model. Older bundles omit it;
        /// then the source repository identifies the model.
        public var spec: String?
        public var name: String
        public var source: Source
        /// The compiled model, relative to the directory.
        public var model: String
        public var inputs: [String]
        public var tokenEmbeddings: TokenEmbeddings?
        public var output: String
        /// The fixed (or enumerated) sequence lengths the model takes.
        public var sequenceLengths: [Int]
        public var fullDimensions: Int
        public var storedDimensions: Int
        /// `mean`, `last-token` or `static`.
        public var pooling: String
        public var queryPrompt: String
        public var documentPrompt: String
        public var computePrecision: String?
        public var weights: String?
        /// The tokenizer, relative to the directory. Defaults to
        /// `tokenizer.json`.
        public var tokenizer: String?

        public init(
            spec: String?, name: String, source: Source, model: String, inputs: [String],
            tokenEmbeddings: TokenEmbeddings?, output: String, sequenceLengths: [Int], fullDimensions: Int,
            storedDimensions: Int, pooling: String, queryPrompt: String, documentPrompt: String,
            computePrecision: String? = nil, weights: String? = nil, tokenizer: String? = nil
        ) {
            self.spec = spec
            self.name = name
            self.source = source
            self.model = model
            self.inputs = inputs
            self.tokenEmbeddings = tokenEmbeddings
            self.output = output
            self.sequenceLengths = sequenceLengths
            self.fullDimensions = fullDimensions
            self.storedDimensions = storedDimensions
            self.pooling = pooling
            self.queryPrompt = queryPrompt
            self.documentPrompt = documentPrompt
            self.computePrecision = computePrecision
            self.weights = weights
            self.tokenizer = tokenizer
        }
    }

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        /// `blau-embedding.json` is missing or unreadable.
        case unreadableMetadata(String)
        /// A file the metadata names isn't there.
        case missingFile(String)
        /// The metadata disagrees with the model spec Blau has for it, so
        /// stored vectors would not mean what the index assumes.
        case specMismatch(String)
        /// The metadata describes something the service can't run.
        case unsupported(String)

        public var description: String {
            switch self {
            case .unreadableMetadata(let detail): "Can't read blau-embedding.json: \(detail)"
            case .missingFile(let path): "The embedding model is missing \(path)"
            case .specMismatch(let detail): "The embedding model doesn't match its spec: \(detail)"
            case .unsupported(let detail): "Unsupported embedding model: \(detail)"
            }
        }
    }

    public static let metadataFileName = "blau-embedding.json"

    public let directory: URL
    public let metadata: Metadata
    /// The model's prompts, widths and pooling, from Blau's own spec when it
    /// knows the model (checked against the metadata), otherwise from the
    /// metadata alone.
    public let spec: TextEmbeddingModelSpec

    /// Reads and checks the bundle in `directory`.
    public init(directory: URL) throws(Failure) {
        let metadataURL = directory.appending(path: Self.metadataFileName)
        let metadata: Metadata
        do {
            metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw .unreadableMetadata(error.localizedDescription)
        }
        try self.init(directory: directory, metadata: metadata)
    }

    public init(directory: URL, metadata: Metadata) throws(Failure) {
        self.directory = directory
        self.metadata = metadata
        self.spec = try Self.spec(for: metadata)

        guard let shortest = metadata.sequenceLengths.min(), shortest > 0 else {
            throw .unsupported("sequence lengths \(metadata.sequenceLengths)")
        }
        guard metadata.storedDimensions > 0, metadata.storedDimensions <= metadata.fullDimensions else {
            throw .unsupported("stored width \(metadata.storedDimensions) of \(metadata.fullDimensions)")
        }
        if let table = metadata.tokenEmbeddings {
            guard TokenEmbeddingTable.Format(rawValue: table.dtype) != nil else {
                throw .unsupported("token table dtype \(table.dtype)")
            }
        }
        for path in [metadata.model, tokenizerPath] + [metadata.tokenEmbeddings?.file].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: directory.appending(path: path).path(percentEncoded: false))
            else { throw .missingFile(path) }
        }
    }

    public var modelURL: URL { directory.appending(path: metadata.model) }
    public var tokenizerURL: URL { directory.appending(path: tokenizerPath) }
    public var tokenEmbeddingsURL: URL? { metadata.tokenEmbeddings.map { directory.appending(path: $0.file) } }
    /// The longest input, special tokens included.
    public var maximumTokens: Int { metadata.sequenceLengths.max() ?? 0 }

    private var tokenizerPath: String { metadata.tokenizer ?? "tokenizer.json" }

    /// Identifies the vectors this bundle produces: the spec's
    /// `vectorIdentifier` (model, stored width, int8, spec revision), the
    /// numerics that change them (compute precision, weight compression,
    /// token table format, sequence length) and the revision of the files,
    /// e.g. `embeddinggemma-300m-256d-int8-r1+fp16.wint8.ti8.L128@57c266a740f5`.
    ///
    /// - Parameter revision: The pinned revision of the installed files
    ///   (`ModelDescriptor.revision`); `nil` uses the source weights'
    ///   revision from the metadata.
    public func modelVersion(revision: String?) -> String {
        var numerics: [String] = []
        if let precision = metadata.computePrecision { numerics.append(precision) }
        if let weights = metadata.weights, weights != "none" { numerics.append("w\(weights)") }
        if let table = metadata.tokenEmbeddings {
            numerics.append(table.dtype == TokenEmbeddingTable.Format.int8.rawValue ? "ti8" : "tf16")
        }
        numerics.append("L\(maximumTokens)")
        let files = String((revision ?? metadata.source.revision).prefix(12))
        return "\(spec.vectorIdentifier)+\(numerics.joined(separator: "."))@\(files)"
    }

    /// The spec for `metadata`: a known model's spec, after checking that the
    /// metadata agrees with it, or one built from the metadata.
    static func spec(for metadata: Metadata) throws(Failure) -> TextEmbeddingModelSpec {
        guard let pooling = pooling(metadata.pooling) else { throw .unsupported("pooling \(metadata.pooling)") }
        let known = TextEmbeddingModelSpec.candidates.first { candidate in
            if let id = metadata.spec { candidate.id == id } else { candidate.source == metadata.source.repo }
        }
        guard let known else {
            if let id = metadata.spec, id.isEmpty { throw .unsupported("empty spec id") }
            return TextEmbeddingModelSpec(
                id: metadata.spec ?? metadata.name.lowercased(),
                displayName: metadata.name,
                source: metadata.source.repo,
                license: metadata.source.license ?? "",
                queryPrompt: metadata.queryPrompt,
                documentPrompt: metadata.documentPrompt,
                fullDimensions: metadata.fullDimensions,
                storedDimensions: metadata.storedDimensions,
                maximumTokens: metadata.sequenceLengths.max() ?? 0,
                pooling: pooling,
                isMatryoshka: metadata.storedDimensions < metadata.fullDimensions
            )
        }
        var mismatches: [String] = []
        if known.queryPrompt != metadata.queryPrompt { mismatches.append("query prompt") }
        if known.documentPrompt != metadata.documentPrompt { mismatches.append("document prompt") }
        if known.fullDimensions != metadata.fullDimensions { mismatches.append("full width") }
        if known.storedDimensions != metadata.storedDimensions { mismatches.append("stored width") }
        if known.pooling != pooling { mismatches.append("pooling") }
        guard mismatches.isEmpty else {
            throw .specMismatch("\(known.id): \(mismatches.joined(separator: ", "))")
        }
        return known
    }

    private static func pooling(_ name: String) -> TextEmbeddingModelSpec.Pooling? {
        switch name {
        case "mean": .mean
        case "last-token", "lastToken": .lastToken
        case "static", "staticMean": .staticMean
        default: nil
        }
    }
}
