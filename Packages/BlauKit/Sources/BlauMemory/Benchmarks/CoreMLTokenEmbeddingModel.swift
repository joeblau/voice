@preconcurrency import CoreML
import Foundation

/// Any Core ML text-embedding model that takes token IDs (and optionally an
/// attention mask) and returns a pooled `[1, D]` or per-token `[1, L, D]`
/// embedding. Used to benchmark EmbeddingGemma-300M, which no Swift package
/// ships yet (#59 picks the model, #60 builds the real service).
///
/// Inputs and outputs are discovered from the model description:
///
/// - the token input is the integer multi-array whose name contains `ids`
///   or `token` (or the only multi-array input);
/// - the mask input, if any, has `mask` in its name;
/// - the output is the first of `sentence_embedding`, `embedding`,
///   `embeddings`, `text_embeds`, `pooler_output`, or else the first
///   multi-array output. Per-token outputs are mean-pooled over the real
///   tokens.
///
/// Fixed-shape models are padded to their length; flexible ones get exactly
/// the tokens (or the nearest enumerated length).
///
/// Models converted by `scripts/embeddings/convert_coreml.py` take
/// `inputs_embeds` (`[1, L, H]` float16) instead of token IDs, so that the
/// Neural Engine can run them (#59): the rows come from a
/// `TokenEmbeddingTable`, by default the `<name>.token-embeddings.f16` file
/// next to the model.
public actor CoreMLTokenEmbeddingModel: TokenEmbeddingModel {
    public nonisolated let url: URL
    private let computeUnits: MLComputeUnits
    private let tokenEmbeddingsURL: URL?
    private var model: MLModel?
    private var layout: Layout?
    private var table: TokenEmbeddingTable?
    private var compiledCopy: URL?

    struct Layout {
        /// What the model's token input is.
        enum Tokens {
            /// Integer token IDs, `[1, L]`.
            case ids(name: String, type: MLMultiArrayDataType)
            /// Input embeddings, `[1, L, width]`, looked up in a
            /// `TokenEmbeddingTable`.
            case embeddings(name: String, type: MLMultiArrayDataType, width: Int)
        }

        var tokens: Tokens
        var maskInput: String?
        var maskType: MLMultiArrayDataType
        var sequence: SequenceShape
        var output: String
    }

    /// The sequence lengths a token input accepts.
    enum SequenceShape: Hashable {
        /// Exactly this length: shorter inputs are padded.
        case fixed(Int)
        /// One of these lengths (ascending): inputs are padded to the
        /// nearest one.
        case enumerated([Int])
        /// Any length in the range: inputs are fed as they are.
        case range(ClosedRange<Int>)

        var maximum: Int {
            switch self {
            case .fixed(let length): length
            case .enumerated(let lengths): lengths.last ?? 0
            case .range(let range): range.upperBound
            }
        }

        /// The length to feed `count` tokens at, or `nil` if too many.
        func length(for count: Int) -> Int? {
            switch self {
            case .fixed(let length): count <= length ? length : nil
            case .enumerated(let lengths): lengths.first { $0 >= count }
            case .range(let range): count <= range.upperBound ? max(count, range.lowerBound) : nil
            }
        }
    }

    /// - Parameters:
    ///   - url: A compiled `.mlmodelc`, or an `.mlpackage` / `.mlmodel` that
    ///     `load()` compiles on device (the compile is part of the measured
    ///     load time).
    ///   - computeUnits: Where Core ML may run the model.
    ///   - tokenEmbeddings: The `TokenEmbeddingTable` file for a model that
    ///     takes `inputs_embeds`. `nil` looks for
    ///     `TokenEmbeddingTable.sibling(of: url)`.
    public init(url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine, tokenEmbeddings: URL? = nil) {
        self.url = url
        self.computeUnits = computeUnits
        self.tokenEmbeddingsURL = tokenEmbeddings
    }

    /// The first `.mlmodelc`, `.mlpackage` or `.mlmodel` whose name starts with
    /// `prefix` (case-insensitive) in any of `directories`, preferring
    /// compiled models.
    public static func locate(named prefix: String, in directories: [URL]) -> URL? {
        let extensions = ["mlmodelc", "mlpackage", "mlmodel"]
        let candidates = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        .filter { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
        for fileExtension in extensions {
            if let match = candidates.filter({ $0.pathExtension == fileExtension }).min(by: {
                $0.lastPathComponent < $1.lastPathComponent
            }) {
                return match
            }
        }
        return nil
    }

    public var maximumSequenceLength: Int { layout?.sequence.maximum ?? 0 }

    public func load() async throws {
        var compiled = url
        if url.pathExtension != "mlmodelc" {
            compiled = try await MLModel.compileModel(at: url)
            compiledCopy = compiled
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
            let layout = try Self.layout(of: model.modelDescription)
            if case .embeddings(let name, _, let width) = layout.tokens {
                guard let tableURL = tokenEmbeddingsURL ?? TokenEmbeddingTable.sibling(of: url) else {
                    throw CoreMLEmbeddingError.missingTokenEmbeddings(name)
                }
                table = try TokenEmbeddingTable(url: tableURL, width: width)
            }
            self.layout = layout
            self.model = model
        } catch {
            // Don't leak the temporary compiled copy when loading fails.
            if compiled != url {
                try? FileManager.default.removeItem(at: compiled)
                if compiledCopy == compiled { compiledCopy = nil }
            }
            throw error
        }
    }

    public func embed(tokenIDs: [Int32]) async throws -> [Float] {
        guard let model, let layout else { throw CoreMLEmbeddingError.notLoaded }
        guard let length = layout.sequence.length(for: tokenIDs.count) else {
            throw CoreMLEmbeddingError.sequenceTooLong(tokenIDs.count, maximum: layout.sequence.maximum)
        }
        let realTokens = tokenIDs.count

        var features: [String: MLFeatureValue] = [:]
        switch layout.tokens {
        case .ids(let name, let type):
            let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: type)
            for index in 0..<length {
                ids[index] = NSNumber(value: index < realTokens ? tokenIDs[index] : 0)
            }
            features[name] = MLFeatureValue(multiArray: ids)
        case .embeddings(let name, let type, let width):
            guard let table else { throw CoreMLEmbeddingError.missingTokenEmbeddings(name) }
            features[name] = MLFeatureValue(
                multiArray: try Self.embeddings(tokenIDs, length: length, width: width, type: type, table: table))
        }
        if let maskInput = layout.maskInput {
            let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: layout.maskType)
            for index in 0..<length {
                mask[index] = NSNumber(value: index < realTokens ? 1 : 0)
            }
            features[maskInput] = MLFeatureValue(multiArray: mask)
        }

        let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: features))
        guard let array = output.featureValue(for: layout.output)?.multiArrayValue else {
            throw CoreMLEmbeddingError.missingOutput(layout.output)
        }
        return Self.pooled(array, realTokens: realTokens)
    }

    /// `[1, length, width]` input embeddings for `tokenIDs`, zero-padded.
    static func embeddings(
        _ tokenIDs: [Int32], length: Int, width: Int, type: MLMultiArrayDataType, table: TokenEmbeddingTable
    ) throws -> MLMultiArray {
        guard type == .float16 else { throw CoreMLEmbeddingError.unsupportedInputs(["inputs_embeds of \(type)"]) }
        guard table.width == width else {
            throw CoreMLEmbeddingError.tableWidthMismatch(table: table.width, model: width)
        }
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: length), NSNumber(value: width)], dataType: .float16)
        let contiguous = array.strides.map(\.intValue) == [length * width, width, 1]
        guard contiguous else { throw CoreMLEmbeddingError.unsupportedInputs(["non-contiguous inputs_embeds"]) }
        var failure: TokenEmbeddingTable.Failure?
        array.withUnsafeMutableBytes { buffer, _ in
            do throws(TokenEmbeddingTable.Failure) {
                try table.copyRows(tokenIDs, length: length, into: buffer)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        return array
    }

    public func unload() async {
        model = nil
        layout = nil
        table = nil
        if let compiledCopy {
            try? FileManager.default.removeItem(at: compiledCopy)
        }
        compiledCopy = nil
    }

    // MARK: Layout discovery

    static func layout(of description: MLModelDescription) throws -> Layout {
        let arrays = description.inputDescriptionsByName.filter { $0.value.type == .multiArray }
        let maskEntry = arrays.first { name, _ in name.lowercased().contains("mask") }
        let embedsEntry = arrays.first { name, _ in name.lowercased().contains("embeds") }
        let tokenEntry =
            embedsEntry
            ?? arrays.first { name, _ in
                let lower = name.lowercased()
                return (lower.contains("ids") || lower.contains("token")) && !lower.contains("mask")
            } ?? (arrays.count == 1 ? arrays.first : nil)
        guard let (tokenName, tokenDescription) = tokenEntry,
            let tokenConstraint = tokenDescription.multiArrayConstraint
        else {
            throw CoreMLEmbeddingError.unsupportedInputs(description.inputDescriptionsByName.keys.sorted())
        }

        // Input embeddings are [1, L, H]: the sequence is the middle
        // dimension, so read it from the mask when there is one.
        let tokens: Layout.Tokens
        let sequenceConstraint: MLMultiArrayConstraint
        if embedsEntry != nil {
            guard let width = tokenConstraint.shape.last?.intValue, width > 0,
                let maskConstraint = maskEntry?.value.multiArrayConstraint
            else {
                throw CoreMLEmbeddingError.unsupportedInputs([tokenName])
            }
            tokens = .embeddings(name: tokenName, type: tokenConstraint.dataType, width: width)
            sequenceConstraint = maskConstraint
        } else {
            tokens = .ids(name: tokenName, type: tokenConstraint.dataType)
            sequenceConstraint = tokenConstraint
        }

        let outputs = description.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        let preferred = ["sentence_embedding", "embedding", "embeddings", "text_embeds", "pooler_output"]
        guard
            let output = preferred.first(where: { outputs[$0] != nil }) ?? outputs.keys.sorted().first
        else {
            throw CoreMLEmbeddingError.missingOutput("a multi-array output")
        }

        guard let sequence = sequenceShape(sequenceConstraint) else {
            throw CoreMLEmbeddingError.unsupportedInputs([tokenName])
        }
        return Layout(
            tokens: tokens,
            maskInput: maskEntry?.key,
            maskType: maskEntry?.value.multiArrayConstraint?.dataType ?? tokenConstraint.dataType,
            sequence: sequence,
            output: output
        )
    }

    /// The sequence lengths (last dimension) a token input accepts. An
    /// unbounded range is capped at 2048 tokens.
    static func sequenceShape(_ constraint: MLMultiArrayConstraint) -> SequenceShape? {
        let shapeConstraint = constraint.shapeConstraint
        switch shapeConstraint.type {
        case .enumerated:
            let lengths = Set(shapeConstraint.enumeratedShapes.compactMap { $0.last?.intValue }).sorted()
            return lengths.isEmpty ? nil : .enumerated(lengths)
        case .range:
            guard let range = shapeConstraint.sizeRangeForDimension.last?.rangeValue else { return nil }
            let lower = max(1, range.location)
            let unbounded = range.length == NSNotFound || range.length > 2_048 - range.location
            let upper = unbounded ? 2_048 : range.location + range.length
            return upper >= lower ? .range(lower...upper) : nil
        default:
            guard let length = constraint.shape.last?.intValue, length > 0 else { return nil }
            return .fixed(length)
        }
    }

    /// `[1, D]` (or `[D]`) as-is; `[1, L, D]` mean-pooled over the first
    /// `realTokens` positions.
    static func pooled(_ array: MLMultiArray, realTokens: Int) -> [Float] {
        let shape = array.shape.map(\.intValue)
        if shape.count >= 3 {
            let length = shape[shape.count - 2]
            let width = shape[shape.count - 1]
            let tokens = max(1, min(realTokens, length))
            var sums = [Float](repeating: 0, count: width)
            for token in 0..<tokens {
                for dimension in 0..<width {
                    sums[dimension] += array[token * width + dimension].floatValue
                }
            }
            return sums.map { $0 / Float(tokens) }
        }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

/// Why a `CoreMLTokenEmbeddingModel` could not load or embed.
public enum CoreMLEmbeddingError: Error, Equatable, CustomStringConvertible {
    case notLoaded
    case unsupportedInputs([String])
    case missingOutput(String)
    case sequenceTooLong(Int, maximum: Int)
    /// The model takes input embeddings and no `TokenEmbeddingTable` was found.
    case missingTokenEmbeddings(String)
    case tableWidthMismatch(table: Int, model: Int)

    public var description: String {
        switch self {
        case .notLoaded: "The model is not loaded"
        case .unsupportedInputs(let names): "Could not find a token-ID input among \(names)"
        case .missingOutput(let name): "The model has no output \(name)"
        case .sequenceTooLong(let count, let maximum): "\(count) tokens exceed the model's maximum of \(maximum)"
        case .missingTokenEmbeddings(let input):
            "The model takes \(input) but there is no <name>.token-embeddings.f16 next to it"
        case .tableWidthMismatch(let table, let model): "The token table is \(table) wide but the model takes \(model)"
        }
    }
}
