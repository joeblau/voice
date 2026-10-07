import Foundation

/// Moves the bytes of one model file from the network to disk.
///
/// The seam between the download manager's logic (resume, retry,
/// verification, network policy) and `URLSession`. Production uses
/// ``URLSessionModelTransport``; tests and previews use in-memory
/// transports.
public protocol ModelTransport: Sendable {
    /// Downloads `url` into `file`.
    ///
    /// When `offset` is greater than zero, `file` already holds that many
    /// bytes of the resource and the transport asks for the rest with an
    /// HTTP `Range` request. If the server answers with the whole resource
    /// instead, the transport overwrites `file` from the start. On return
    /// the response body has been written completely; the caller checks the
    /// size and checksum.
    ///
    /// - Parameters:
    ///   - allowsExpensiveNetwork: Whether cellular, personal hotspot and
    ///     Low Data Mode networks may be used. When `false` and only such a
    ///     network is available, throws
    ///     ``ModelTransportError/expensiveNetworkDisallowed``.
    ///   - onProgress: Called with the file's length as bytes arrive, from
    ///     any thread.
    /// - Throws: ``ModelTransportError`` or `CancellationError`.
    func fetch(
        _ url: URL,
        into file: URL,
        resumingAt offset: Int64,
        allowsExpensiveNetwork: Bool,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws
}

/// Why a transfer failed, classified for the retry and network policy.
public enum ModelTransportError: Error, Hashable, Sendable {
    /// No network connection. Wait for one, then resume.
    case offline
    /// Only an expensive or constrained network (cellular, hotspot, Low
    /// Data Mode) is available and the policy doesn't allow it. Wait for
    /// Wi-Fi, then resume.
    case expensiveNetworkDisallowed
    /// The server answered with this HTTP status.
    case httpStatus(Int)
    /// The connection dropped or timed out mid-transfer. Retry and resume.
    case interrupted(String)
    /// Writing to disk failed (usually a full disk).
    case writeFailed(String)

    /// Whether trying the same request again soon can succeed.
    var isTransient: Bool {
        switch self {
        case .interrupted: true
        case .httpStatus(let status): status == 408 || status == 429 || (500...599).contains(status)
        case .offline, .expensiveNetworkDisallowed, .writeFailed: false
        }
    }
}
