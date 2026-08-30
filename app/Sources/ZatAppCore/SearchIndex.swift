import Foundation
import Zat

/// One indexed record: enough to match and to open the record (via the same
/// path → at:// URI synthesis `OfflineRepo` uses), without holding the full
/// decoded JSON tree in the index.
public struct SearchIndexEntry: Sendable, Equatable, Codable {
    /// The MST key, "collection/rkey" — the same path `OfflineRepo` shapes
    /// records from, so a hit opens the identical record the browser shows.
    public let path: String
    /// Multibase CID of the record block.
    public let cid: String
    /// The extracted searchable fields.
    public let fields: SearchFields

    public init(path: String, cid: String, fields: SearchFields) {
        self.path = path
        self.cid = cid
        self.fields = fields
    }

    /// "collection/rkey" → "collection", for kind/collection display.
    public var collection: String { OfflineRepo.collection(of: path) }
}

/// A loaded, validated search index for one repo.
public struct SearchIndexData: Sendable, Equatable {
    public let did: String
    public let indexedAt: Date
    public let entries: [SearchIndexEntry]

    public init(did: String, indexedAt: Date, entries: [SearchIndexEntry]) {
        self.did = did
        self.indexedAt = indexedAt
        self.entries = entries
    }
}

/// Disk storage for the per-repo local search index, owned by the same
/// cache directory as `RepoCache` (one `<did>.searchindex.jsonl` beside the
/// CAR). Built at mirror time from the records the mirror already decodes.
///
/// **Format.** A line-oriented file: one header line, then one JSON object
/// per record, UTF-8, in path order. Line-oriented (not a single JSON array)
/// so a mirror writes it streaming and a future incremental live sync can
/// rewrite only affected lines instead of one giant blob.
///
/// **Validation.** The header carries the schema version and the record
/// count at index time. `load` treats the index as valid only when the
/// schema matches and the count equals the caller's `recordCount` (the
/// `index.json` value), so a stale index after a re-mirror, corruption, or a
/// format bump each fail validation and the caller falls back to building
/// from the decoded repo. `store` writes atomically (temp file + rename), so
/// a crashed mirror never leaves a half-written index.
public enum SearchIndex {
    /// Bump when the entry/header shape changes; `load` rejects mismatches.
    public static let schemaVersion = 1

    /// The index file URL for a repo inside a cache directory.
    public static func url(forRepo did: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(did).searchindex.jsonl", isDirectory: false)
    }

    /// Extract the index entries for decoded CAR records (also the
    /// in-memory fallback when no valid on-disk index exists).
    public static func entries(from records: [ZatCarRecord]) -> [SearchIndexEntry] {
        records.map { SearchIndexEntry(path: $0.path, cid: $0.cid, fields: SearchFields(value: $0.value)) }
    }

    /// Build and persist the index for a repo's decoded records. Throws
    /// `AppError.cache` on write failure; atomic (temp file + rename) so a
    /// crash mid-write never corrupts a previously good index.
    public static func store(
        did: String,
        records: [ZatCarRecord],
        in directory: URL,
        indexedAt: Date = Date()
    ) throws {
        try write(did: did, entries: entries(from: records), in: directory, indexedAt: indexedAt)
    }

    /// Persist a pre-built set of entries — the lazy-fallback path, which has
    /// already extracted `SearchFields` in memory and skips re-extracting
    /// them. Same format and atomicity as the records-based store.
    public static func store(
        did: String,
        entries: [SearchIndexEntry],
        in directory: URL,
        indexedAt: Date = Date()
    ) throws {
        try write(did: did, entries: entries, in: directory, indexedAt: indexedAt)
    }

    private static func write(
        did: String,
        entries: [SearchIndexEntry],
        in directory: URL,
        indexedAt: Date
    ) throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let finalURL = url(forRepo: did, in: directory)
        let tempURL = finalURL.appendingPathExtension("tmp")
        do {
            _ = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)

            let header = Header(
                schemaVersion: schemaVersion, did: did,
                recordCount: entries.count, indexedAt: indexedAt)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            // Keep paths like app.bsky.feed.post/1 greppable in the raw file.
            encoder.outputFormatting = .withoutEscapingSlashes
            try handle.write(contentsOf: try encoder.encode(header))
            try handle.write(contentsOf: Data("\n".utf8))
            for entry in entries {
                try handle.write(contentsOf: try encoder.encode(entry))
                try handle.write(contentsOf: Data("\n".utf8))
            }
            try handle.close()
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            if let error = error as? AppError { throw error }
            throw AppError.cache("couldn't save the search index: \(error.localizedDescription)")
        }
    }

    /// Load and validate a repo's index. Nil when the file is missing,
    /// corrupt, or stale (schema bump or `recordCount` mismatch) — the
    /// caller then rebuilds from the decoded repo.
    public static func load(did: String, recordCount: Int, in directory: URL) -> SearchIndexData? {
        let url = url(forRepo: did, in: directory)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let headerLine = lines.first else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let header = try? decoder.decode(Header.self, from: Data(headerLine.utf8)),
              header.schemaVersion == schemaVersion,
              header.did == did,
              header.recordCount == recordCount else { return nil }

        var entries: [SearchIndexEntry] = []
        entries.reserveCapacity(lines.count - 1)
        for line in lines.dropFirst() {
            guard let entry = try? decoder.decode(SearchIndexEntry.self, from: Data(line.utf8)) else {
                return nil
            }
            entries.append(entry)
        }
        guard entries.count == recordCount else { return nil }
        return SearchIndexData(did: did, indexedAt: header.indexedAt, entries: entries)
    }

    /// Delete a repo's index file. Missing files are a no-op.
    public static func remove(did: String, in directory: URL) {
        try? FileManager.default.removeItem(at: url(forRepo: did, in: directory))
    }

    /// Header line of a `jsonl` index: schema version, repo, record count,
    /// and when it was built — the validation key on load.
    private struct Header: Codable {
        var schemaVersion: Int
        var did: String
        var recordCount: Int
        var indexedAt: Date
    }
}
