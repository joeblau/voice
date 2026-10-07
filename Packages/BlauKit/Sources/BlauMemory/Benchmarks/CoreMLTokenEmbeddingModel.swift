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
public actor CoreMLTokenEmbeddingModel: TokenEmbeddingModel {
    public nonisolated let url: URL
    private let computeUnits: MLComputeUnits
    private var model: MLModel?
    private var layout: Layout?
    private var compiledCopy: URL?

    struct Layout {
        var tokenInput: String
        var tokenType: MLMultiArrayDataType
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

    /// - Parameter url: A compiled `.mlmodelc`, or an `.mlpackage` /
    ///   `.mlmodel` that `load()` compiles on device (the compile is part of
    ///   the measured load time).
    public init(url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        self.url = url
        self.computeUnits = computeUnits
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
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        layout = try Self.layout(of: model.modelDescription)
        self.model = model
    }

    public func embed(tokenIDs: [Int32]) async throws -> [Float] {
        guard let model, let layout else { throw CoreMLEmbeddingError.notLoaded }
        guard let length = layout.sequence.length(for: tokenIDs.count) else {
            throw CoreMLEmbeddingError.sequenceTooLong(tokenIDs.count, maximum: layout.sequence.maximum)
        }
        let realTokens = tokenIDs.count

        var features: [String: MLFeatureValue] = [:]
        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: layout.tokenType)
        for index in 0..<length {
            ids[index] = NSNumber(value: index < realTokens ? tokenIDs[index] : 0)
        }
        features[layout.tokenInput] = MLFeatureValue(multiArray: ids)
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

    public func unload() async {
        model = nil
        layout = nil
        if let compiledCopy {
            try? FileManager.default.removeItem(at: compiledCopy)
        }
        compiledCopy = nil
    }

    // MARK: Layout discovery

    static func layout(of description: MLModelDescription) throws -> Layout {
        let arrays = description.inputDescriptionsByName.filter { $0.value.type == .multiArray }
        let tokenEntry =
            arrays.first { name, _ in
                let lower = name.lowercased()
                return (lower.contains("ids") || lower.contains("token")) && !lower.contains("mask")
            } ?? (arrays.count == 1 ? arrays.first : nil)
        guard let (tokenName, tokenDescription) = tokenEntry,
            let tokenConstraint = tokenDescription.multiArrayConstraint
        else {
            throw CoreMLEmbeddingError.unsupportedInputs(description.inputDescriptionsByName.keys.sorted())
        }
        let maskEntry = arrays.first { name, _ in name.lowercased().contains("mask") }

        let outputs = description.outputDescriptionsByName.filter { $0.value.type == .multiArray }
        let preferred = ["sentence_embedding", "embedding", "embeddings", "text_embeds", "pooler_output"]
        guard
            let output = preferred.first(where: { outputs[$0] != nil }) ?? outputs.keys.sorted().first
        else {
            throw CoreMLEmbeddingError.missingOutput("a multi-array output")
        }

        guard let sequence = sequenceShape(tokenConstraint) else {
            throw CoreMLEmbeddingError.unsupportedInputs([tokenName])
        }
        return Layout(
            tokenInput: tokenName,
            tokenType: tokenConstraint.dataType,
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

enum CoreMLEmbeddingError: Error, CustomStringConvertible {
    case notLoaded
    case unsupportedInputs([String])
    case missingOutput(String)
    case sequenceTooLong(Int, maximum: Int)

    var description: String {
        switch self {
        case .notLoaded: "The model is not loaded"
        case .unsupportedInputs(let names): "Could not find a token-ID input among \(names)"
        case .missingOutput(let name): "The model has no output \(name)"
        case .sequenceTooLong(let count, let maximum): "\(count) tokens exceed the model's maximum of \(maximum)"
        }
    }
}
