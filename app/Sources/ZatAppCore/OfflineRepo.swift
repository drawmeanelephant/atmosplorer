import Foundation
import Zat

/// A decoded repo CAR, shaped for offline browsing.
///
/// Pure value type: everything is derived from `ZatRecordCar` (whose records
/// arrive in MST key order from the core's CAR walk). It powers the offline
/// view — collections in sorted order, per-collection record lists sorted by
/// rkey, and at:// URIs synthesized from the DID + MST path — and is fully
/// testable without any view or network involvement.
public struct OfflineRepo: Sendable, Equatable {
    public let did: String
    public let records: [ZatCarRecord]

    public init(did: String, recordCar: ZatRecordCar) {
        self.did = did
        self.records = recordCar.records
    }

    public var recordCount: Int { records.count }

    /// The repo's collections, in sorted order (the MST walk order is by
    /// path, not by collection).
    public var collections: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for record in records {
            let collection = Self.collection(of: record.path)
            if seen.insert(collection).inserted {
                result.append(collection)
            }
        }
        return result.sorted()
    }

    /// One collection's records, sorted by rkey, as `ZatRecord` values so the
    /// offline views reuse the exact same rows/detail as the live walk.
    public func records(in collection: String) -> [ZatRecord<ZatJSONValue>] {
        records
            .filter { Self.collection(of: $0.path) == collection }
            .sorted { Self.rkey(of: $0.path) < Self.rkey(of: $1.path) }
            .map { record in
                ZatRecord(uri: "at://\(did)/\(record.path)", cid: record.cid, value: record.value)
            }
    }

    /// "collection/rkey" → "collection".
    public static func collection(of path: String) -> String {
        path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    }

    /// "collection/rkey" → "rkey".
    public static func rkey(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
