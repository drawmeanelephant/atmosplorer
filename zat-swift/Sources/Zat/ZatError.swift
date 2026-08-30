import Czat
import Foundation

/// Errors surfaced by the zat C ABI, mirroring `zat_status` from zat.h.
///
/// Status values are matched numerically so the wrapper is immune to how the
/// C importer renames enum cases. The numbering is part of the ABI contract
/// documented in include/zat.h:
/// 0 ok, 1 invalidArgument, 2 invalidIdentifier, 3 invalidResponse,
/// 4 missingField, 5 missingPds, 6 network, 7 outOfMemory, 8 unexpected.
public enum ZatError: Error, Equatable, Sendable {
    case invalidArgument
    case invalidIdentifier
    case invalidResponse
    case missingField
    case missingPds
    case network
    case outOfMemory
    case unexpected

    /// Maps a `zat_status` onto a `ZatError`.
    init(_ status: zat_status) {
        switch status.rawValue {
        case 1: self = .invalidArgument
        case 2: self = .invalidIdentifier
        case 3: self = .invalidResponse
        case 4: self = .missingField
        case 5: self = .missingPds
        case 6: self = .network
        case 7: self = .outOfMemory
        default: self = .unexpected
        }
    }

    /// Throws unless the call succeeded (`ZAT_OK` == 0).
    static func check(_ status: zat_status) throws {
        if status.rawValue != 0 {
            throw ZatError(status)
        }
    }

    /// Throws unless the call succeeded. When the failed call carried an XRPC
    /// error envelope (a non-2xx response from the network), throws
    /// `ZatXrpcError` so hosts can distinguish `RateLimitExceeded`,
    /// `InvalidRequest`, and specific HTTP statuses; validation failures that
    /// never reached the network throw the plain `ZatError`.
    static func check(_ status: zat_status, details: inout zat_error_details) throws {
        if status.rawValue != 0 {
            if let details = takeZatErrorDetails(&details) {
                throw ZatXrpcError(code: ZatError(status), details: details)
            }
            throw ZatError(status)
        }
    }
}

/// The XRPC error envelope of a failed network call, mirrored from
/// `zat_error_details` in zat.h.
public struct ZatErrorDetails: Equatable, Sendable {
    /// HTTP status code (e.g. 400, 429); 0 when no HTTP response was received.
    public let httpStatus: Int
    /// XRPC error name (e.g. "InvalidRequest", "RateLimitExceeded"), when the
    /// response body was a JSON envelope carrying one.
    public let errorName: String?
    /// Human-readable message from the envelope, when present.
    public let message: String?
    /// Retry-After header in seconds; nil when absent.
    public let retryAfterSeconds: Int?

    init(_ raw: zat_error_details) {
        httpStatus = Int(raw.http_status)
        errorName = readZatString(raw.error_name)
        message = readZatString(raw.message)
        retryAfterSeconds = raw.retry_after >= 0 ? Int(raw.retry_after) : nil
    }
}

/// A network call that failed with a non-2xx XRPC response. `code` is the
/// ABI status (typically `.invalidResponse`); `details` carries the error
/// envelope.
public struct ZatXrpcError: Error, Equatable, Sendable {
    public let code: ZatError
    public let details: ZatErrorDetails
}

extension ZatXrpcError: LocalizedError {
    public var errorDescription: String? {
        if let message = details.message, !message.isEmpty {
            return message
        }
        if let errorName = details.errorName, !errorName.isEmpty {
            return "\(errorName) (HTTP \(details.httpStatus))"
        }
        return "XRPC request failed (HTTP \(details.httpStatus))"
    }
}
