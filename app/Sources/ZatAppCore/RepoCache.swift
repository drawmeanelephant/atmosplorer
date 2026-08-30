import Foundation

/// One repo persisted by `RepoCache`.
public struct CachedRepo: Sendable, Equatable, Identifiable {
    /// The repo's DID; unique key of the cache entry and the CAR filename.
    public let did: String
    /// The handle known at download time, if any (display sugar only).
    public let handle: String?
    /// When the CAR was last downloaded.
    public let cachedAt: Date
    /// Number of records the CAR decoded to at download time, so the library
    /// list can show a size without decoding every file.
    public let recordCount: Int
    /// The CAR's size in bytes at download time (older entries may lack it).
    public let carByteCount: Int?
    /// Mirror snapshots across successive downloads of the same DID, oldest
    /// first. Pre-history entries (indexes written before this field existed)
    /// yield a single-element list.
    public let history: [CachedRepoMirror]

    public var id: String { did }

    /// Best display name: handle when present, else the DID.
    public var displayName: String { handle ?? did }

    /// Number of times this repo has been mirrored (1 for pre-history entries).
    public var mirrorCount: Int { max(history.count, 1) }

    /// Byte delta from the first to the latest mirror that has a size, when
    /// there is more than one; nil otherwise.
    public var sizeGrowthBytes: Int? {
        let sized = history.compactMap { $0.carByteCount }
        guard sized.count >= 2, let first = sized.first, let last = sized.last else { return nil }
        return last - first
    }

    public init(
        did: String, handle: String?, cachedAt: Date,
        recordCount: Int, carByteCount: Int? = nil,
        history: [CachedRepoMirror] = []
    ) {
        self.did = did
        self.handle = handle
        self.cachedAt = cachedAt
        self.recordCount = recordCount
        self.carByteCount = carByteCount
        self.history = history
    }
}

/// One mirror event for a cached repo — a single successful download.
public struct CachedRepoMirror: Sendable, Equatable {
    public let cachedAt: Date
    public let recordCount: Int
    public let carByteCount: Int?

    public init(cachedAt: Date, recordCount: Int, carByteCount: Int?) {
        self.cachedAt = cachedAt
        self.recordCount = recordCount
        self.carByteCount = carByteCount
    }
}

/// Disk storage for offline repo browsing.
///
/// **Design decision (documented):** a repo's CAR is self-contained — the
/// commit block, every MST node, and every record block — so the offline
/// story is \"one file per repo\". `save` writes `<did>.car` atomically next
/// to a small `index.json` mapping DID → {handle, cachedAt, recordCount,
/// mirror history}; listing reads the index only (no decoding), and browsing
/// loads the single file and hands it to `AppSession.decodeCar`. Each `save`
/// appends to the DID's mirror history so the library can show repo growth
/// over time from successive downloads. The DID is the filename and
/// the index key (handles change; DIDs don't). A corrupt index degrades to
/// empty rather than failing the app; orphaned `.car` files are then simply
/// invisible until a later milestone garbage-collects them.
///
/// Methods are safe to call from any thread (NSLock); the app only touches
/// this from the main actor, but tests exercise it directly. All failures
/// surface as `AppError.cache` so views keep their single error type.
public final class RepoCache: @unchecked Sendable {
    public let directory: URL

    private let indexURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    /// Create a cache rooted at `directory`, creating it if needed. Defaults
    /// to `~/Library/Application Support/Atmosplorer/caches`; inject a
    /// temporary directory in tests.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? Self.defaultDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.indexURL = self.directory.appendingPathComponent("index.json", isDirectory: false)
        // Best-effort: a failure here surfaces later, when save() can't write.
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("Atmosplorer", isDirectory: true)
            .appendingPathComponent("caches", isDirectory: true)
    }

    /// Persist a repo CAR. `recordCount` is the decoded record count at
    /// download time (shown in listings without re-decoding). Overwriting an
    /// existing DID refreshes the entry in place and appends a mirror to its
    /// history, so the library list can show repo growth over time.
    public func save(did: String, handle: String?, car: Data, recordCount: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let carURL = carURL(for: did)
        do {
            try car.write(to: carURL, options: .atomic)
        } catch {
            throw AppError.cache("couldn't write the repo file: \(error.localizedDescription)")
        }
        var index = readIndex()

        let snapshot = MirrorSnapshot(
            cachedAt: Date(), recordCount: recordCount, carByteCount: car.count)
        var mirrors = index[did]?.mirrors ?? []
        if let existing = index[did], mirrors.isEmpty {
            // An index written before history existed: preserve its single
            // mirror so growth isn't lost across an upgrade.
            mirrors.append(MirrorSnapshot(
                cachedAt: existing.cachedAt, recordCount: existing.recordCount,
                carByteCount: existing.carByteCount))
        }
        mirrors.append(snapshot)
        index[did] = Entry(
            handle: handle, cachedAt: snapshot.cachedAt,
            recordCount: recordCount, carByteCount: car.count, mirrors: mirrors)
        do {
            try writeIndex(index)
        } catch {
            // The CAR landed but the index didn't; don't leave an orphan the
            // list can't see.
            try? fileManager.removeItem(at: carURL)
            throw error
        }
    }

    /// All cached repos, most recently downloaded first. Reading the index
    /// never touches the CAR files.
    public func cachedRepos() throws -> [CachedRepo] {
        lock.lock()
        defer { lock.unlock() }
        return readIndex()
            .map {
                let history = ($0.value.mirrors ?? []).map {
                    CachedRepoMirror(
                        cachedAt: $0.cachedAt, recordCount: $0.recordCount,
                        carByteCount: $0.carByteCount)
                }
                let fallback = [CachedRepoMirror(
                    cachedAt: $0.value.cachedAt, recordCount: $0.value.recordCount,
                    carByteCount: $0.value.carByteCount)]
                return CachedRepo(
                    did: $0.key, handle: $0.value.handle,
                    cachedAt: $0.value.cachedAt,
                    recordCount: $0.value.recordCount,
                    carByteCount: $0.value.carByteCount,
                    history: history.isEmpty ? fallback : history)
            }
            .sorted { $0.cachedAt > $1.cachedAt }
    }

    /// The raw CAR bytes for `did`. `.cache` when nothing is stored.
    public func load(did: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let url = carURL(for: did)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AppError.cache("no cached repo for \(did)")
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw AppError.cache("couldn't read the repo file: \(error.localizedDescription)")
        }
    }

    /// Remove a repo and its index entry. Missing entries are a no-op.
    public func delete(did: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: carURL(for: did))
        try? fileManager.removeItem(at: mapURL(forRepo: did, suffix: "names"))
        try? fileManager.removeItem(at: mapURL(forRepo: did, suffix: "entities"))
        try? fileManager.removeItem(at: SearchIndex.url(forRepo: did, in: directory))
        var index = readIndex()
        index.removeValue(forKey: did)
        try writeIndex(index)
    }

    // MARK: - resolved names ("as people" persistence)

    /// The repo's persisted subject-DID → handle map (from dependency resolution
    /// during previous offline browses). Stored alongside the CAR as
    /// `<did>.names.json` so a repo browsed online shows the same people
    /// offline later, without re-resolving. Empty when none stored; a corrupt
    /// file degrades to empty rather than failing the browse.
    public func loadNames(forRepo did: String) -> [String: String] {
        loadMap(forRepo: did, suffix: "names")
    }

    /// Record one resolved subject (subjectDID → handle) for a repo, merging
    /// into any existing names file. Failures are swallowed — the in-memory
    /// resolver still holds the value for the session, so a failed write only
    /// costs some reuse later, never a visible error.
    public func storeName(_ handle: String, forSubject subjectDID: String, inRepo did: String) throws {
        try storeMap([subjectDID: handle], forRepo: did, suffix: "names")
    }

    /// After a mirror, drop persisted names for subjects this repo no longer
    /// references, so re-mirroring never keeps showing people the repo
    /// dropped. Pass the set of person identifiers still present in the latest
    /// decoded CAR (see `RecordContent.referencedPersonIdentifiers`); names for
    /// referenced subjects survive, anything else is pruned. No-op when there's
    /// nothing to drop, and safe on a missing/corrupt names file.
    public func pruneNames(forRepo did: String, referencing referenced: Set<String>) throws {
        try pruneMap(forRepo: did, suffix: "names", referencing: referenced)
    }

    // MARK: - resolved entities (starter-pack feeds)

    /// The repo's persisted feed-generator DID → name map (`<did>.entities.json`),
    /// kept **separate from the people map** so starter-pack feeds never share
    /// the account-name cache. Same semantics as `loadNames`.
    public func loadEntities(forRepo did: String) -> [String: String] {
        loadMap(forRepo: did, suffix: "entities")
    }

    /// Record one resolved entity (feed-generator DID → name), merging into
    /// the entities file. Same semantics as `storeName`.
    public func storeEntity(_ name: String, forSubject subjectDID: String, inRepo did: String) throws {
        try storeMap([subjectDID: name], forRepo: did, suffix: "entities")
    }

    /// Prune entities this repo no longer references (see
    /// `RecordContent.referencedEntityIdentifiers`). Same semantics as
    /// `pruneNames`.
    public func pruneEntities(forRepo did: String, referencing referenced: Set<String>) throws {
        try pruneMap(forRepo: did, suffix: "entities", referencing: referenced)
    }

    // MARK: - private

    /// `<did>.<suffix>.json`, e.g. `did:plc:x.names.json`.
    private func mapURL(forRepo did: String, suffix: String) -> URL {
        directory.appendingPathComponent("\(did).\(suffix).json", isDirectory: false)
    }

    private func loadMap(forRepo did: String, suffix: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let url = mapURL(forRepo: did, suffix: suffix)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    /// Merges `entries` into the map and writes it back atomically. Throws
    /// `AppError.cache` on failure.
    private func storeMap(_ entries: [String: String], forRepo did: String, suffix: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var map = loadMapUnlocked(forRepo: did, suffix: suffix) ?? [:]
        map.merge(entries) { _, new in new }
        try writeMap(map, forRepo: did, suffix: suffix)
    }

    /// Drops every key not in `referenced`; no-op when nothing would change.
    private func pruneMap(forRepo did: String, suffix: String, referencing referenced: Set<String>) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var map = loadMapUnlocked(forRepo: did, suffix: suffix) else { return }
        let before = map.count
        map = map.filter { referenced.contains($0.key) }
        guard map.count != before else { return }
        try writeMap(map, forRepo: did, suffix: suffix)
    }

    /// Loads a map without taking the lock (callers hold it).
    private func loadMapUnlocked(forRepo did: String, suffix: String) -> [String: String]? {
        let url = mapURL(forRepo: did, suffix: suffix)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func writeMap(_ map: [String: String], forRepo did: String, suffix: String) throws {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(map)
            try data.write(to: mapURL(forRepo: did, suffix: suffix), options: .atomic)
        } catch {
            throw AppError.cache("couldn't save resolved \(suffix): \(error.localizedDescription)")
        }
    }

    private struct Entry: Codable {
        var handle: String?
        var cachedAt: Date
        var recordCount: Int
        /// Optional so indexes written before this field existed still decode.
        var carByteCount: Int?
        /// Optional mirror history (old indexes lack it; new saves always set it).
        var mirrors: [MirrorSnapshot]?
    }

    private struct MirrorSnapshot: Codable {
        var cachedAt: Date
        var recordCount: Int
        var carByteCount: Int?
    }

    private func carURL(for did: String) -> URL {
        directory.appendingPathComponent("\(did).car", isDirectory: false)
    }

    private func namesURL(forRepo did: String) -> URL {
        directory.appendingPathComponent("\(did).names.json", isDirectory: false)
    }

    /// Loads names without taking the lock (callers hold it).
    private func loadNamesUnlocked(forRepo did: String) -> [String: String]? {
        let url = namesURL(forRepo: did)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func readIndex() -> [String: Entry] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        let decoder = JSONDecoder()
        // secondsSince1970 keeps sub-second precision, so "most recent first"
        // ordering is exact even for back-to-back saves (ISO8601 truncates
        // to whole seconds and ties would keep insertion order).
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private func writeIndex(_ index: [String: Entry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            throw AppError.cache("couldn't save the cache index: \(error.localizedDescription)")
        }
    }
}
