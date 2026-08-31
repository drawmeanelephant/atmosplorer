import Foundation
import Zat

/// One record the user bookmarked for later. The decoded `value` is stored
/// alongside the URI, so the Favorites list renders and opens detail views
/// with zero network — the record's repo CAR needn't even be cached anymore.
public struct FavoriteRecord: Sendable, Equatable, Identifiable, Codable {
    /// Full at:// URI of the record; unique key of the favorite.
    public let uri: String
    /// Content-addressed identifier, when known at save time.
    public let cid: String?
    /// The decoded record body.
    public let value: ZatJSONValue
    /// Repo the record came from (display grouping in the sidebar).
    public let repoDid: String
    /// Human name of the repo at save time (handle when known, else the DID).
    public let repoName: String
    /// When the record was bookmarked; the Favorites list is newest-first.
    public let addedAt: Date

    public var id: String { uri }

    public init(
        uri: String, cid: String?, value: ZatJSONValue,
        repoDid: String, repoName: String, addedAt: Date = Date()
    ) {
        self.uri = uri
        self.cid = cid
        self.value = value
        self.repoDid = repoDid
        self.repoName = repoName
        self.addedAt = addedAt
    }
}

/// Disk storage for bookmarked records.
///
/// One `favorites.json` file in the same Application Support directory the
/// repo cache uses (`~/Library/Application Support/Atmosplorer/caches`), so a
/// favorites store constructed with the cache's directory shares the app's
/// single on-disk home. The value is stored in full (it's `Codable`), which
/// is what makes the Favorites list fully offline: opening a favorite never
/// consults the network or even the CAR.
///
/// Semantics mirror `RepoCache`: methods are safe from any thread (NSLock),
/// writes are atomic, a missing/corrupt file degrades to empty rather than
/// failing the sidebar, and failures surface as `AppError.cache`.
public final class FavoritesStore: @unchecked Sendable {
    public let directory: URL

    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    /// Create a store rooted at `directory`, creating it if needed. Defaults
    /// to the same directory as `RepoCache`; inject a temporary directory in
    /// tests.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? RepoCache.defaultDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.fileURL = self.directory.appendingPathComponent("favorites.json", isDirectory: false)
        // Best-effort: a failure here surfaces later, when a write can't land.
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// All favorites, newest first. Missing or corrupt storage degrades to
    /// empty, never a throw.
    public func favorites() -> [FavoriteRecord] {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked().sorted { $0.addedAt > $1.addedAt }
    }

    /// Whether `uri` is bookmarked — drives the detail-view star state.
    public func contains(uri: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return readUnlocked().contains { $0.uri == uri }
    }

    /// Bookmark a record. Re-adding an existing URI refreshes it in place
    /// (new timestamp, back to the top of the newest-first list). Throws
    /// `AppError.cache` on write failure.
    @discardableResult
    public func add(
        uri: String, cid: String?, value: ZatJSONValue,
        repoDid: String, repoName: String, addedAt: Date = Date()
    ) throws -> FavoriteRecord {
        lock.lock()
        defer { lock.unlock() }
        var all = readUnlocked()
        all.removeAll { $0.uri == uri }
        let record = FavoriteRecord(
            uri: uri, cid: cid, value: value,
            repoDid: repoDid, repoName: repoName, addedAt: addedAt)
        all.append(record)
        try writeUnlocked(all)
        return record
    }

    /// Remove a bookmark. Missing entries are a no-op.
    public func remove(uri: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = readUnlocked()
        let before = all.count
        all.removeAll { $0.uri == uri }
        guard all.count != before else { return }
        try writeUnlocked(all)
    }

    /// Add if absent, remove if present. Returns whether the record is now
    /// bookmarked (so the UI can flip its star and, when appropriate, close
    /// a favorite being unstarred).
    @discardableResult
    public func toggle(
        uri: String, cid: String?, value: ZatJSONValue,
        repoDid: String, repoName: String, addedAt: Date = Date()
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = readUnlocked()
        if let index = all.firstIndex(where: { $0.uri == uri }) {
            all.remove(at: index)
            try writeUnlocked(all)
            return false
        } else {
            all.append(FavoriteRecord(
                uri: uri, cid: cid, value: value,
                repoDid: repoDid, repoName: repoName, addedAt: addedAt))
            try writeUnlocked(all)
            return true
        }
    }

    // MARK: - private

    private func readUnlocked() -> [FavoriteRecord] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL)
        else { return [] }
        let decoder = JSONDecoder()
        // secondsSince1970 keeps sub-second precision, so "newest first"
        // ordering is exact even for back-to-back saves (ISO8601 truncates
        // to whole seconds and ties would keep insertion order).
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([FavoriteRecord].self, from: data)) ?? []
    }

    private func writeUnlocked(_ records: [FavoriteRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw AppError.cache(
                "couldn't save favorites: \(error.localizedDescription)")
        }
    }
}
