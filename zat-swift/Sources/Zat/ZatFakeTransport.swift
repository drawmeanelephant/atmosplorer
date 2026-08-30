import Czat
import Foundation

/// A scripted transport for deterministic `ZatExplorer` tests — no network,
/// no sleeps. Responses are consumed in FIFO order; requests are recorded
/// (count, last URL) for assertions. A 429 queued with `retryAfter: 0`
/// exercises the retry path instantly, because a zero delay skips sleeping.
///
/// ```swift
/// let fake = try ZatFakeTransport()
/// try fake.queue(status: 200, body: #"{"records":[], "cursor":null}"#)
/// let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)
/// ```
///
/// The transport is independent of the sessions it feeds: it must outlive
/// every explorer created with it. `ZatExplorer` retains its transport, so
/// keeping the explorer alive keeps the fake alive.
public final class ZatFakeTransport {
    private let handle: OpaquePointer

    public init() throws {
        var created: OpaquePointer? = nil
        try ZatError.check(zat_fake_transport_create(&created))
        guard let created else { throw ZatError.unexpected }
        self.handle = created
    }

    deinit {
        zat_fake_transport_destroy(handle)
    }

    /// Queue the next response (chaining style). `status` is an HTTP status
    /// code (200/201/204/400/401/403/404/409/429/500/502/503/504);
    /// `retryAfter < 0` means "no retry-after header"; `0` exercises retries
    /// without sleeping. The body is copied.
    @discardableResult
    public func queue(status: Int, body: String, retryAfter: Int = -1) throws -> ZatFakeTransport {
        try ZatError.check(zat_fake_transport_queue_response(
            handle, Int32(clamping: status), body, Int32(clamping: retryAfter)))
        return self
    }

    /// Number of requests served so far.
    public var requestCount: Int {
        Int(zat_fake_transport_request_count(handle))
    }

    /// URL of the most recent request, exactly as built by the C layer
    /// (including percent-encoding). Throws `.invalidArgument` before any
    /// request has been served.
    public func lastURL() throws -> String {
        var raw = zat_string()
        try ZatError.check(zat_fake_transport_last_url(handle, &raw))
        guard let url = takeZatString(&raw) else { throw ZatError.unexpected }
        return url
    }

    var cHandle: OpaquePointer { handle }
}
