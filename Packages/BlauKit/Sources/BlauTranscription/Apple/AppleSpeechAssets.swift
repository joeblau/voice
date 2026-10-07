import BlauTelemetry
import Foundation
import os

#if canImport(Speech)
    import Speech
#endif

/// Whether Apple's on-device transcriber can run for a language.
public enum AppleSpeechAvailability: Hashable, Sendable {
    /// This device can't run `SpeechTranscriber` at all.
    case unsupportedDevice
    /// `SpeechTranscriber` has no model for the language (the requested
    /// locale's identifier).
    case unsupportedLocale(String)
    /// Supported, but the language's model isn't on the device yet. It
    /// downloads (managed by the system) the first time the engine is
    /// prepared.
    case notInstalled(locale: String)
    /// The system is downloading the model.
    case downloading(locale: String)
    /// Ready to transcribe.
    case installed(locale: String)

    /// Whether the engine can be prepared now (possibly after a download).
    public var isSupported: Bool {
        switch self {
        case .unsupportedDevice, .unsupportedLocale: false
        case .notInstalled, .downloading, .installed: true
        }
    }

    /// Whether it can transcribe without downloading anything.
    public var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Why the Apple engine couldn't be used.
public enum AppleSpeechError: Error, Hashable, Sendable {
    /// This device can't run `SpeechTranscriber`.
    case unsupportedDevice
    /// No model for the language (the requested locale's identifier).
    case unsupportedLocale(String)
    /// The model isn't installed and downloading wasn't allowed.
    case assetsNotInstalled(String)
    /// The analyzer reported no audio format it can take.
    case noCompatibleAudioFormat
    /// `append` or `finalize` before `start`.
    case notStarted
}

extension AppleSpeechError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedDevice: "This device doesn't support on-device speech recognition."
        case .unsupportedLocale(let locale): "On-device speech recognition isn't available for \(locale)."
        case .assetsNotInstalled(let locale): "The speech recognition model for \(locale) isn't downloaded."
        case .noCompatibleAudioFormat: "Speech recognition can't take the microphone's audio format."
        case .notStarted: "Speech recognition hasn't started."
        }
    }
}

/// Checks and prepares Apple's speech models (`AssetInventory`), so the
/// router knows whether the fallback can run and `SystemSpeechAnalyzerEngine`
/// finds its model installed.
///
/// The models belong to the system, not to Blau: they are shared with other
/// apps, downloaded and updated by the system, and don't count against
/// Blau's storage.
public enum AppleSpeechAssets {
    /// Whether the transcriber can run for `locale` (the user's language by
    /// default).
    public static func availability(for locale: Locale = .current) async -> AppleSpeechAvailability {
        #if canImport(Speech)
            return await SystemSpeechAssets.availability(for: locale)
        #else
            return .unsupportedDevice
        #endif
    }

    /// Resolves the transcriber's locale for `locale`, reserves it for Blau
    /// and installs its model if needed.
    ///
    /// - Parameter allowsDownload: When `false`, throws
    ///   `AppleSpeechError.assetsNotInstalled` instead of downloading.
    /// - Returns: The locale to create the engine with.
    public static func prepare(for locale: Locale = .current, allowsDownload: Bool = true) async throws -> Locale {
        #if canImport(Speech)
            return try await SystemSpeechAssets.prepare(for: locale, allowsDownload: allowsDownload)
        #else
            throw AppleSpeechError.unsupportedDevice
        #endif
    }

    /// The locales Apple's transcriber supports on this device, for
    /// Settings → Transcription → Language. Empty when the device can't run
    /// it.
    public static func supportedLocales() async -> [Locale] {
        #if canImport(Speech)
            guard SpeechTranscriber.isAvailable else { return [] }
            return await SpeechTranscriber.supportedLocales
        #else
            return []
        #endif
    }
}

#if canImport(Speech)
    enum SystemSpeechAssets {
        static func availability(for locale: Locale) async -> AppleSpeechAvailability {
            guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return .unsupportedLocale(locale.identifier)
            }
            let identifier = resolved.identifier
            if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == identifier }) {
                return .installed(locale: identifier)
            }
            let module = SpeechTranscriber(locale: resolved, preset: SystemSpeechAnalyzerEngine.preset)
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return .installed(locale: identifier)
            case .downloading: return .downloading(locale: identifier)
            case .supported: return .notInstalled(locale: identifier)
            case .unsupported: return .unsupportedLocale(locale.identifier)
            @unknown default: return .notInstalled(locale: identifier)
            }
        }

        static func prepare(for locale: Locale, allowsDownload: Bool) async throws -> Locale {
            guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.unsupportedDevice }
            guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw AppleSpeechError.unsupportedLocale(locale.identifier)
            }
            let module = SpeechTranscriber(locale: resolved, preset: SystemSpeechAnalyzerEngine.preset)

            // An app may hold a few locales at once
            // (`AssetInventory.maximumReservedLocales`); reserving keeps the
            // model from being reclaimed while Blau may need it. A failure
            // here (too many reserved) doesn't stop the installation below.
            if await !AssetInventory.reservedLocales.contains(where: { $0.identifier == resolved.identifier }) {
                do {
                    try await AssetInventory.reserve(locale: resolved)
                } catch {
                    Log.asr.notice(
                        "Couldn't reserve \(resolved.identifier, privacy: .public) for Apple ASR: \(String(describing: error), privacy: .public)"
                    )
                }
            }

            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                guard allowsDownload else { throw AppleSpeechError.assetsNotInstalled(resolved.identifier) }
                Log.asr.notice("Downloading the Apple speech model for \(resolved.identifier, privacy: .public)")
                try await request.downloadAndInstall()
                Log.asr.notice("Apple speech model for \(resolved.identifier, privacy: .public) installed")
            }
            return resolved
        }
    }
#endif
