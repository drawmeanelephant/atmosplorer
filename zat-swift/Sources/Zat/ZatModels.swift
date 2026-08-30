import Foundation

/// Result of resolving a handle or DID through the AT Protocol identity chain.
public struct ZatIdentity: Sendable, Equatable, Hashable {
    /// The account's DID; always present on success.
    public let did: String
    /// Primary handle advertised by the DID document, if any.
    public let handle: String?
    /// Repo host advertised by the DID document, if any. Absent for foreign
    /// or incomplete DID documents — treat as "unknown", not failure.
    public let pds: String?

    public init(did: String, handle: String?, pds: String?) {
        self.did = did
        self.handle = handle
        self.pds = pds
    }

    /// The PDS as a URL, when present and well-formed.
    public var pdsURL: URL? {
        pds.flatMap(URL.init(string:))
    }
}

/// Summary of a repository: its DID and the collections it holds.
public struct ZatRepoDescription: Sendable, Equatable, Hashable {
    public let did: String
    public let collections: [String]
}

/// One record fetched or listed, with its value decoded into `Value`.
public struct ZatRecord<Value> {
    /// Full at:// URI of the record.
    public let uri: String
    /// Content-addressed identifier, when the response includes one.
    public let cid: String?
    /// The decoded record body.
    public let value: Value

    public init(uri: String, cid: String?, value: Value) {
        self.uri = uri
        self.cid = cid
        self.value = value
    }
}

/// One page of a collection listing, as returned by `listRecords`.
public struct ZatRecordPage<Value> {
    public let records: [ZatRecord<Value>]
    /// Cursor for the next page, or nil once the listing is exhausted.
    public let cursor: String?
}

// Value types over Sendable contents may cross actor boundaries (e.g. an
// app awaiting `listRecords` from a @MainActor model), so they are Sendable
// whenever their payload is.
extension ZatRecord: Sendable where Value: Sendable {}
extension ZatRecordPage: Sendable where Value: Sendable {}

/// One record decoded from a repo CAR. `path` is the MST key
/// ("collection/rkey"); `value` is the record body decoded from DAG-CBOR
/// into `ZatJSONValue` (the same JSON tree used for listRecords).
public struct ZatCarRecord: Sendable, Equatable {
    public let path: String
    /// Multibase CID string ("bafy...") of the record block.
    public let cid: String
    public let value: ZatJSONValue

    public init(path: String, cid: String, value: ZatJSONValue) {
        self.path = path
        self.cid = cid
        self.value = value
    }
}

/// Every record of a repo CAR, decoded offline from the raw CAR bytes
/// (commit block + MST walk + record blocks). Records are in MST key order.
public struct ZatRecordCar: Sendable, Equatable {
    public let records: [ZatCarRecord]

    public init(records: [ZatCarRecord]) {
        self.records = records
    }
}

// MARK: - internal decode envelopes

/// Shape of a com.atproto.repo.getRecord response body.
struct RecordEnvelope<Value: Decodable>: Decodable {
    let uri: String
    let cid: String?
    let value: Value
}

/// Shape of a com.atproto.repo.listRecords response body.
struct RecordPageEnvelope<Value: Decodable>: Decodable {
    struct Entry: Decodable {
        let uri: String
        let cid: String?
        let value: Value
    }

    let records: [Entry]
    let cursor: String?
}

/// Shape of a com.atproto.repo.describeRepo response body (subset).
struct RepoDescriptionEnvelope: Decodable {
    let did: String
    let collections: [String]
}
