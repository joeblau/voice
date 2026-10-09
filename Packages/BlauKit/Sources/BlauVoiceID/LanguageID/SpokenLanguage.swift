import Foundation

/// A spoken language the language filter (#50) can recognize, by its ISO 639
/// code (`en`, `es`, `zh`, `he`...).
///
/// The codes are the language identification model's labels
/// (``VoxLingua107``), with its two legacy codes modernized (`iw` is `he`,
/// `jw` is `jv`). Norwegian is `no` (the model also has Nynorsk, `nn`) and
/// Tagalog is `tl`; ``init(locale:)`` maps the device's codes (`nb`, `fil`,
/// `yue`...) onto them.
public struct SpokenLanguage: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// The ISO 639 code.
    public let code: String

    /// A language by its code, if the model knows it.
    public init?(code: String) {
        let normalized = code.lowercased()
        let canonical = Self.aliases[normalized] ?? normalized
        guard VoxLingua107.codes.contains(canonical) else { return nil }
        self.code = canonical
    }

    /// The language of `locale` (its language code; region and script are
    /// ignored), if the model knows it.
    public init?(locale: Locale) {
        guard let identifier = locale.language.languageCode?.identifier else { return nil }
        self.init(code: identifier)
    }

    /// The language of a BCP 47 identifier such as `en-US` or `zh-Hans-CN`.
    public init?(identifier: String) {
        self.init(locale: Locale(identifier: identifier))
    }

    private init(validated code: String) {
        self.code = code
    }

    /// Encoded as its code. Decoding fails for a code the model doesn't
    /// know.
    public init(from decoder: any Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        guard let language = SpokenLanguage(code: code) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown language code \(code)"))
        }
        self = language
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    public static func < (lhs: SpokenLanguage, rhs: SpokenLanguage) -> Bool { lhs.code < rhs.code }

    public var description: String { code }

    /// The language's name in `locale` ("Spanish", "Español"...).
    public func localizedName(in locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code) ?? VoxLingua107.englishNames[code] ?? code
    }

    /// Languages that count as this one when it is allowed: so close that
    /// the model splits their speech between them, and nobody would want
    /// one filtered out when they speak the other. Scots for English, the
    /// two written Norwegians, Serbian, Croatian and Bosnian, Malay and
    /// Indonesian.
    public var equivalents: Set<SpokenLanguage> {
        Self.equivalenceGroups.first { $0.contains(code) }
            .map { Set($0.map(SpokenLanguage.init(validated:))) } ?? [self]
    }

    /// Every language the model recognizes, in its label order.
    public static let all: [SpokenLanguage] = VoxLingua107.codes.map(SpokenLanguage.init(validated:))

    public static let english = SpokenLanguage(validated: "en")

    /// The device's preferred languages (`Locale.preferredLanguages`) the
    /// model knows, in order of preference, without duplicates.
    public static func preferred(_ identifiers: [String] = Locale.preferredLanguages) -> [SpokenLanguage] {
        var seen = Set<SpokenLanguage>()
        return identifiers.compactMap(SpokenLanguage.init(identifier:)).filter { seen.insert($0).inserted }
    }

    /// Device codes for languages the model has under another code.
    static let aliases: [String: String] = [
        "iw": "he", "jw": "jv", "nb": "no", "fil": "tl", "yue": "zh", "wuu": "zh", "cmn": "zh", "in": "id",
        "ji": "yi",
    ]

    static let equivalenceGroups: [Set<String>] = [
        ["en", "sco"], ["no", "nn"], ["sr", "hr", "bs"], ["ms", "id"],
    ]
}

/// The label set of SpeechBrain's ECAPA-TDNN VoxLingua107 language
/// identification model: 107 languages, in the order of the model's
/// `log_probabilities` output (the model's `labels.json`, which
/// ``VoxLinguaLanguageIdentifier/load(modelDirectory:computeUnits:)`` checks).
public enum VoxLingua107 {
    /// The model's codes as ``SpokenLanguage`` codes, in output order.
    public static let codes: [String] = modelCodes.map { SpokenLanguage.aliases[$0] ?? $0 }

    /// The codes exactly as the model's `labels.json` has them.
    public static let modelCodes: [String] = [
        "ab", "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "ceb", "cs", "cy", "da",
        "de", "el", "en", "eo", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gn", "gu", "gv", "ha", "haw", "hi",
        "hr", "ht", "hu", "hy", "ia", "id", "is", "it", "iw", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb",
        "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc",
        "pa", "pl", "ps", "pt", "ro", "ru", "sa", "sco", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv",
        "sw", "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "war", "yi", "yo", "zh",
    ]

    /// English names, for codes the system has no name for.
    static let englishNames: [String: String] = [
        "ceb": "Cebuano", "haw": "Hawaiian", "ia": "Interlingua", "sco": "Scots", "war": "Waray",
    ]
}
