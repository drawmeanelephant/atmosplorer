import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `SearchIndex` — the per-repo `jsonl` store: write at
/// mirror time, validate on load (schema + record count), degrade to nil on
/// missing/corrupt/stale files, and clean up with `RepoCache.delete`.
final class SearchIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosplorer-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ path: String, text: String) -> ZatCarRecord {
        ZatCarRecord(path: path, cid: "bafy-\(path)", value: [
            "$type": "app.bsky.feed.post",
            "text": .string(text),
        ])
    }

    // MARK: round trip

    func testStoreAndLoadRoundTrip() throws {
        let records = [
            record("app.bsky.feed.post/1", text: "hello"),
            record("app.bsky.feed.post/2", text: "world"),
        ]
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try SearchIndex.store(did: "did:plc:search1", records: records, in: directory, indexedAt: indexedAt)

        let loaded = try XCTUnwrap(SearchIndex.load(
            did: "did:plc:search1", recordCount: 2, in: directory))
        XCTAssertEqual(loaded.did, "did:plc:search1")
        XCTAssertEqual(loaded.indexedAt, indexedAt)
        XCTAssertEqual(loaded.entries.count, 2)
        XCTAssertEqual(loaded.entries[0].path, "app.bsky.feed.post/1")
        XCTAssertEqual(loaded.entries[1].fields.text, [.init(text: "world", weight: .high)])
    }

    func testStorePrebuiltEntriesRoundTrip() throws {
        // The lazy-fallback path: entries already extracted in memory, then
        // persisted without re-extracting them from records.
        let entries = [
            SearchIndexEntry(
                path: "app.bsky.feed.post/1", cid: "bafy-1",
                fields: SearchFields(value: ["$type": "app.bsky.feed.post", "text": "hello"])),
        ]
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try SearchIndex.store(
            did: "did:plc:prebuilt", entries: entries, in: directory, indexedAt: indexedAt)

        let loaded = try XCTUnwrap(SearchIndex.load(
            did: "did:plc:prebuilt", recordCount: 1, in: directory))
        XCTAssertEqual(loaded.entries, entries)
        XCTAssertEqual(loaded.indexedAt, indexedAt)
    }

    func testStoreOverwritesPreviousIndex() throws {
        let records = [record("app.bsky.feed.post/1", text: "hello")]
        try SearchIndex.store(did: "did:plc:search1", records: records, in: directory)
        // Re-mirror with more records (stale count is what makes old indexes
        // invalid).
        let more = [records[0], record("app.bsky.feed.post/2", text: "world")]
        try SearchIndex.store(did: "did:plc:search1", records: more, in: directory)

        let loaded = try XCTUnwrap(SearchIndex.load(
            did: "did:plc:search1", recordCount: 2, in: directory))
        XCTAssertEqual(loaded.entries.count, 2)
    }

    func testLoadMissingReturnsNil() {
        XCTAssertNil(SearchIndex.load(did: "did:plc:nope", recordCount: 1, in: directory))
    }

    // MARK: validation

    func testLoadCorruptFileReturnsNil() throws {
        let url = SearchIndex.url(forRepo: "did:plc:broken", in: directory)
        try Data("not json at all".utf8).write(to: url)
        XCTAssertNil(SearchIndex.load(did: "did:plc:broken", recordCount: 1, in: directory))
    }

    func testLoadStaleRecordCountReturnsNil() throws {
        let records = [record("app.bsky.feed.post/1", text: "hello")]
        try SearchIndex.store(did: "did:plc:stale", records: records, in: directory)
        // index.json says 2 records now; the index still has 1 → stale.
        XCTAssertNil(SearchIndex.load(did: "did:plc:stale", recordCount: 2, in: directory))
        // Correct count loads fine.
        XCTAssertNotNil(SearchIndex.load(did: "did:plc:stale", recordCount: 1, in: directory))
    }

    func testLoadWrongDIDReturnsNil() throws {
        let records = [record("app.bsky.feed.post/1", text: "hello")]
        try SearchIndex.store(did: "did:plc:mine", records: records, in: directory)
        XCTAssertNil(SearchIndex.load(did: "did:plc:theirs", recordCount: 1, in: directory))
    }

    func testLoadSchemaBumpReturnsNil() throws {
        let url = SearchIndex.url(forRepo: "did:plc:bumped", in: directory)
        // A future format bumps schemaVersion; old readers must reject it
        // rather than misparse.
        let header = #"{"schemaVersion":2,"did":"did:plc:bumped","recordCount":1,"indexedAt":1700000000}"#
        try Data((header + "\n").utf8).write(to: url)
        XCTAssertNil(SearchIndex.load(did: "did:plc:bumped", recordCount: 1, in: directory))
    }

    // MARK: layout

    func testIndexFileIsLineOriented() throws {
        let records = [record("app.bsky.feed.post/1", text: "hello")]
        try SearchIndex.store(did: "did:plc:lines", records: records, in: directory)

        let url = SearchIndex.url(forRepo: "did:plc:lines", in: directory)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2) // header + 1 record
        XCTAssertTrue(lines[0].contains("\"schemaVersion\":1"))
        XCTAssertTrue(lines[0].contains("\"recordCount\":1"))
        XCTAssertTrue(lines[1].contains("\"app.bsky.feed.post/1\""))
    }

    func testNoTempFileLeftBehind() throws {
        let records = [record("app.bsky.feed.post/1", text: "hello")]
        try SearchIndex.store(did: "did:plc:clean", records: records, in: directory)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: RepoCache integration

    func testRepoCacheDeleteRemovesIndex() throws {
        let cache = RepoCache(directory: directory)
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: "did:plc:search-del", handle: "x.test", car: car, recordCount: 2)
        try SearchIndex.store(did: "did:plc:search-del", records: [
            record("app.bsky.feed.post/1", text: "hello"),
            record("app.bsky.feed.post/2", text: "world"),
        ], in: directory)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: SearchIndex.url(forRepo: "did:plc:search-del", in: directory).path))

        try cache.delete(did: "did:plc:search-del")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: SearchIndex.url(forRepo: "did:plc:search-del", in: directory).path))
    }

    // MARK: end to end (real fixture CAR, no network)

    /// The milestone demo for search, fully offline: decode the fixture CAR
    /// the way `CachedRepoBrowserModel` does, index the records, and search
    /// them — the same path the browser will take on first use.
    func testSearchFixtureCarEndToEnd() async throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        let session = try AppSession(host: "https://example.invalid")
        let decoded = try await session.decodeCar(car)
        XCTAssertEqual(decoded.records.count, 2)

        let entries = SearchIndex.entries(from: decoded.records)
        try SearchIndex.store(did: "did:plc:test123", records: decoded.records, in: directory)
        let loaded = try XCTUnwrap(SearchIndex.load(
            did: "did:plc:test123", recordCount: 2, in: directory))

        let results = LocalSearch.results(for: "world", in: loaded.entries)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].entry.fields.text, [.init(text: "world", weight: .high)])
        // A hit resolves to the same at:// URI the offline browser builds.
        let uri = "at://did:plc:test123/\(results[0].entry.path)"
        XCTAssertTrue(uri.hasPrefix("at://did:plc:test123/app.bsky.feed.post/"))

        XCTAssertTrue(LocalSearch.results(for: "hello", in: entries).count == 1)
        XCTAssertTrue(LocalSearch.results(for: "goodbye", in: loaded.entries).isEmpty)
    }
}
