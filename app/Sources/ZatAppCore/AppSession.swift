import Foundation
import Zat

/// An async session over the (blocking, C-backed) `ZatExplorer` wrapper.
///
/// **Async decision (documented):** `ZatExplorer` runs blocking C calls and
/// is explicitly not thread-safe (the ABI contract says "one per thread, or
/// serialize access"). We serialize by owning exactly one explorer behind a
/// dedicated serial `DispatchQueue`, and expose `async` methods that bridge
/// with `withCheckedThrowingContinuation`. The blocking calls therefore never
/// run on the main thread or on the Swift cooperative pool, and the explorer
/// is only ever touched from its own queue — which is what makes this class
/// `@unchecked Sendable` sound.
///
/// This is the single seam where the app talks to the network, so it is also
/// the single place the error model is applied: every method throws
/// `AppError` (see AppError.swift), never the raw wrapper errors.
public final class AppSession: @unchecked Sendable {
    private let queue: DispatchQueue
    private let explorer: ZatExplorer
    /// The base URL this session is bound to (bootstrap appview or PDS).
    private let host: String

    /// Create a session bound to `host` (e.g. "https://bsky.social" for the
    /// public bootstrap reads, or an identity's PDS for sync endpoints).
    ///
    /// Pass a `ZatFakeTransport` to serve all XRPC traffic from a script
    /// instead of the network (identity resolution still uses the network).
    public init(host: String, fakeTransport: ZatFakeTransport? = nil) throws {
        self.explorer = try ZatExplorer(host: host, fakeTransport: fakeTransport)
        self.host = host
        // A fresh label per host keeps each session's queue identifiable.
        self.queue = DispatchQueue(label: "atmosplorer.session.\(host)")
    }

    /// Create a session bound to the identity's PDS (sync endpoints like
    /// getRepo live there, not on appviews). `.missingPds` when the DID
    /// document advertises none.
    public static func dataSession(for identity: ZatIdentity) throws -> AppSession {
        guard let pds = identity.pds else { throw AppError.missingPds }
        return try AppSession(host: pds)
    }

    /// Resolve a handle or DID through the AT Protocol identity chain.
    public func resolveIdentity(_ identifier: String) async throws -> ZatIdentity {
        try await run { try $0.resolveIdentity(identifier) }
    }

    /// List the collections a repo holds (com.atproto.repo.describeRepo).
    public func describeRepo(_ repo: String) async throws -> ZatRepoDescription {
        try await run { try $0.describeRepo(repo) }
    }

    /// One page of a collection listing. Pass `cursor` back in to continue;
    /// nil `cursor` in the result means the listing is exhausted.
    public func listRecords(
        repo: String,
        collection: String,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> ZatRecordPage<ZatJSONValue> {
        try await run { try $0.listRecords(
            repo: repo, collection: collection, limit: limit, cursor: cursor,
            as: ZatJSONValue.self) }
    }

    /// Fetch a repo's raw CAR bytes (`com.atproto.sync.getRepo`). Sync
    /// endpoints are served by the identity's PDS, so use a
    /// `dataSession(for:)` session. The bytes are self-contained — persist
    /// them (RepoCache) and `decodeCar` works forever after, offline.
    public func fetchRepoCar(did: String) async throws -> Data {
        try await run { try $0.fetchRepoCar(did: did) }
    }

    /// Probe how big a repo's CAR download would be, via an HTTP HEAD on the
    /// `getRepo` endpoint (the sync endpoint served by the identity's PDS).
    /// Returns `nil` when the server doesn't advertise a `Content-Length`
    /// (streamed/chunked responses, or any probe failure) so callers degrade
    /// to an unconfirmed download instead of failing. This is pure URLSession
    /// plumbing on the seam, not a core call, so it costs no C ABI surface.
    public func probeRepoCarSize(did: String) async -> Int? {
        guard let encoded = did.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(host)/xrpc/com.atproto.sync.getRepo?did=\(encoded)&format=car")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let length = http.value(forHTTPHeaderField: "Content-Length"),
              let bytes = Int(length),
              bytes > 0
        else { return nil }
        return bytes
    }

    /// Fetch a repo's full CAR and decode every record, fully offline once
    /// the bytes are here (commit block + MST walk in the core).
    public func fetchRepoCarRecords(did: String) async throws -> ZatRecordCar {
        try await run { try $0.fetchRepoCarRecords(did: did) }
    }

    /// Decode a repo CAR you already hold (e.g. from disk) into records.
    public func decodeCar(_ data: Data) async throws -> ZatRecordCar {
        try await run { try $0.recordCar(from: data) }
    }

    // MARK: - private

    /// Run a blocking explorer call on the session's serial queue, bridging
    /// to async. Maps every thrown error through `AppError.from` so callers
    /// only ever see `AppError`.
    private func run<T>(_ body: @escaping @Sendable (ZatExplorer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result(catching: {
                    do { return try body(self.explorer) }
                    catch { throw AppError.from(error) }
                })
                continuation.resume(with: result)
            }
        }
    }
}
