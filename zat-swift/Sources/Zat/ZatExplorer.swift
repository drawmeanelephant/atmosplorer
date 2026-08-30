import Czat
import Foundation

/// A session against one AT Protocol host.
///
/// The session owns the underlying C handle and releases it in `deinit`;
/// callers never touch the `zat_*` C functions or `zat_free` directly.
///
/// Not thread-safe (mirrors the C ABI contract in zat.h): use one session per
/// thread or serialize access. Values returned from calls are plain Swift
/// value types and are safe to pass anywhere.
///
/// Typical exploration flow — a bootstrap session for public lookups, then a
/// data session on the resolved PDS for sync endpoints:
///
///     let bootstrap = try ZatExplorer(host: "https://bsky.social")
///     let identity = try bootstrap.resolveIdentity("atproto.com")
///     let description = try bootstrap.describeRepo(identity.did)
///     let page = try bootstrap.listRecords(
///         repo: identity.did, collection: "app.bsky.feed.post")
///     let pds = try bootstrap.dataSession(for: identity)
///     let car = try pds.fetchRepoCar(did: identity.did)
public final class ZatExplorer {
    // the C typedef `struct zat_explorer` is never completed, so it imports
    // as OpaquePointer — the same handle pattern as sqlite3
    private let handle: OpaquePointer
    /// Retains a scripted transport so the explorer keeps it alive.
    private let retainedTransport: ZatFakeTransport?

    /// Version of the underlying zat core.
    public static var coreVersion: String {
        String(cString: zat_version())
    }

    /// Creates a session bound to `host`, which serves the public bootstrap
    /// reads (e.g. "https://bsky.social"). Pass a `ZatFakeTransport` to serve
    /// all XRPC traffic from a script instead of the network (identity
    /// resolution still uses the network).
    public init(host: String, fakeTransport: ZatFakeTransport? = nil) throws {
        guard !host.isEmpty else { throw ZatError.invalidArgument }
        var created: OpaquePointer? = nil
        if let fakeTransport {
            try ZatError.check(zat_explorer_create_with_fake(host, fakeTransport.cHandle, &created))
        } else {
            try ZatError.check(zat_explorer_create(host, &created))
        }
        guard let created else { throw ZatError.unexpected }
        self.handle = created
        self.retainedTransport = fakeTransport
    }

    deinit {
        zat_explorer_destroy(handle)
    }

    /// Resolve a handle or DID to did/handle/PDS via the AT Protocol identity
    /// chain (DNS-over-HTTPS / well-known for handles, PLC / did:web for DIDs).
    public func resolveIdentity(_ identifier: String) throws -> ZatIdentity {
        var raw = zat_identity()
        try ZatError.check(zat_resolve_identity(handle, identifier, &raw))
        defer { zat_identity_deinit(&raw) }
        guard let did = readZatString(raw.did) else { throw ZatError.unexpected }
        return ZatIdentity(
            did: did,
            handle: readZatString(raw.handle),
            pds: readZatString(raw.pds)
        )
    }

    /// Opens a second session bound to the identity's PDS, which serves the
    /// sync endpoints (e.g. `fetchRepoCar`) that appviews decline.
    public func dataSession(for identity: ZatIdentity) throws -> ZatExplorer {
        guard let pds = identity.pds else { throw ZatError.missingPds }
        return try ZatExplorer(host: pds)
    }

    /// Fetch one record by full at:// URI (including collection and rkey) and
    /// decode its value into `Value`. Use `ZatJSONValue` when you don't have
    /// a dedicated model.
    public func getRecord<Value: Decodable>(
        at uri: String,
        as type: Value.Type = Value.self
    ) throws -> ZatRecord<Value> {
        var raw = zat_string()
        var details = zat_error_details()
        try ZatError.check(zat_get_record_json(handle, uri, &raw, &details), details: &details)
        guard let body = takeZatString(&raw) else { throw ZatError.unexpected }
        let envelope = try Self.decoder.decode(
            RecordEnvelope<Value>.self, from: Data(body.utf8))
        return ZatRecord(uri: envelope.uri, cid: envelope.cid, value: envelope.value)
    }

    /// Fetch one page of a collection listing (`com.atproto.repo.listRecords`).
    ///
    /// `limit == nil` means the server default; pass `page.cursor` back in to
    /// continue paging. A nil `page.cursor` means the listing is exhausted.
    public func listRecords<Value: Decodable>(
        repo: String,
        collection: String,
        limit: Int? = nil,
        cursor: String? = nil,
        as type: Value.Type = Value.self
    ) throws -> ZatRecordPage<Value> {
        var raw = zat_string()
        var details = zat_error_details()
        try ZatError.check(
            zat_list_records_json(
                handle, repo, collection,
                UInt32(limit ?? 0), cursor, &raw, &details),
            details: &details)
        guard let body = takeZatString(&raw) else { throw ZatError.unexpected }
        let envelope = try Self.decoder.decode(
            RecordPageEnvelope<Value>.self, from: Data(body.utf8))
        return ZatRecordPage(
            records: envelope.records.map {
                ZatRecord(uri: $0.uri, cid: $0.cid, value: $0.value)
            },
            cursor: envelope.cursor
        )
    }

    /// Describe a repo: its DID and the collections it holds
    /// (`com.atproto.repo.describeRepo`).
    public func describeRepo(_ repo: String) throws -> ZatRepoDescription {
        var raw = zat_string()
        var details = zat_error_details()
        try ZatError.check(zat_describe_repo_json(handle, repo, &raw, &details), details: &details)
        guard let body = takeZatString(&raw) else { throw ZatError.unexpected }
        let envelope = try Self.decoder.decode(
            RepoDescriptionEnvelope.self, from: Data(body.utf8))
        return ZatRepoDescription(did: envelope.did, collections: envelope.collections)
    }

    /// Fetch the repo's full CAR — every record plus the MST that indexes
    /// them (`com.atproto.sync.getRepo`). Sync endpoints are served by the
    /// account's PDS, so prefer `dataSession(for:)` over an appview session.
    public func fetchRepoCar(did: String) throws -> Data {
        var raw = zat_blob()
        var details = zat_error_details()
        try ZatError.check(zat_fetch_repo_car(handle, did, &raw, &details), details: &details)
        guard let car = takeZatBlob(&raw) else { throw ZatError.unexpected }
        return car
    }

    /// Decode every record of a repo CAR (commit block + MST walk + record
    /// blocks, all DAG-CBOR) into an owned listing, offline. Records are in
    /// MST key order; each carries its path ("collection/rkey"), multibase
    /// CID, and the record body as `ZatJSONValue`.
    public func recordCar(from carData: Data) throws -> ZatRecordCar {
        var raw: UnsafeMutablePointer<zat_car_records>? = nil
        try carData.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            try ZatError.check(zat_iterate_car_records(
                base.assumingMemoryBound(to: UInt8.self),
                bytes.count, &raw))
        }
        guard let records = raw else { throw ZatError.unexpected }
        defer { zat_car_records_deinit(records) }

        let count = Int(records.pointee.count)
        var decoded: [ZatCarRecord] = []
        decoded.reserveCapacity(count)
        for index in 0..<count {
            let entry = records.pointee.records[index]
            guard let path = readZatString(entry.path),
                  let cid = readZatString(entry.cid),
                  let json = readZatString(entry.json)
            else { throw ZatError.unexpected }
            let value = try Self.decoder.decode(ZatJSONValue.self, from: Data(json.utf8))
            decoded.append(ZatCarRecord(path: path, cid: cid, value: value))
        }
        return ZatRecordCar(records: decoded)
    }

    /// Fetch a repo's full CAR and decode every record in one call. Sync
    /// endpoints are served by the account's PDS, so prefer a
    /// `dataSession(for:)` session.
    public func fetchRepoCarRecords(did: String) throws -> ZatRecordCar {
        try recordCar(from: fetchRepoCar(did: did))
    }

    // MARK: - private

    private static let decoder = JSONDecoder()
}
