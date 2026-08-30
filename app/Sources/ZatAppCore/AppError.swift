import Foundation
import Zat

/// The single user-facing error type of the app.
///
/// **Error-model decision (documented):** the wrapper distinguishes "never
/// reached the network" (`ZatError`) from "network responded with an XRPC
/// error envelope" (`ZatXrpcError`). The app collapses those into one
/// `AppError` with a message a human can read, in exactly one place
/// (`AppError.from`), so views never switch over raw wrapper errors and new
/// failure modes stay confined to this file. The underlying error is kept
/// for logging/debugging.
public enum AppError: Error, Equatable {
    /// The input didn't parse as a handle or DID (validated before any
    /// network activity).
    case invalidIdentifier(String)
    /// The repo's DID document advertises no PDS, so sync endpoints are
    /// unavailable.
    case missingPds
    /// The server rate-limited the request; `retryAfter` in seconds, when
    /// the response carried a Retry-After header.
    case rateLimited(retryAfter: Int?)
    /// A non-2xx XRPC response. `message` is the envelope message (or a
    /// synthesized one), `status` the HTTP status code.
    case server(message: String, status: Int)
    /// A transport-level failure (connection, TLS, timeout, DNS).
    case network
    /// The local offline cache (CAR storage) failed — read, write, or
    /// missing entry. `message` is a human-readable detail.
    case cache(String)
    /// Anything else — malformed response, internal error.
    case unexpected

    /// Map any error the wrapper can throw onto `AppError`.
    public static func from(_ error: Error) -> AppError {
        switch error {
        case let error as ZatXrpcError:
            let details = error.details
            if details.errorName == "RateLimitExceeded" || details.httpStatus == 429 {
                return .rateLimited(retryAfter: details.retryAfterSeconds)
            }
            let message = details.message.flatMap { $0.isEmpty ? nil : $0 }
                ?? details.errorName
                ?? "The request failed"
            return .server(message: message, status: details.httpStatus)
        case let error as ZatError:
            switch error {
            case .invalidIdentifier: return .invalidIdentifier("")
            case .missingPds: return .missingPds
            case .network: return .network
            default: return .unexpected
            }
        default:
            return .unexpected
        }
    }

    /// A message ready to show in an alert or inline error row.
    public var userMessage: String {
        switch self {
        case .invalidIdentifier(let input):
            let shown = input.isEmpty ? "that" : "\"\(input)\""
            return "\(shown) doesn't look like a handle or DID."
        case .missingPds:
            return "This account's DID document doesn't advertise a PDS, so its repo can't be reached."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Try again in \(retryAfter) second\(retryAfter == 1 ? "" : "s")."
            }
            return "Rate limited. Try again in a moment."
        case .server(let message, let status):
            return "\(message) (HTTP \(status))"
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .cache(let message):
            return "Couldn't use the offline copy: \(message)"
        case .unexpected:
            return "Something unexpected went wrong."
        }
    }
}
