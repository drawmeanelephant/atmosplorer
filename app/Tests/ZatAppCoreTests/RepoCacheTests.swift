import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `RepoCache` — persist CAR bytes to disk, list cached
/// repos, load them back, delete. Every test uses a throwaway directory and
/// no network at all.
final class RepoCacheTests: XCTestCase {
    private var directory: URL!
    private var cache: RepoCache!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosplorer-tests-\(UUID().uuidString)", isDirectory: true)
        cache = RepoCache(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveListLoadDeleteRoundTrip() throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: "did:plc:test123", handle: "alice.test", car: car, recordCount: 2)

        let repos = try cache.cachedRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].did, "did:plc:test123")
        XCTAssertEqual(repos[0].handle, "alice.test")
        XCTAssertEqual(repos[0].recordCount, 2)
        XCTAssertEqual(repos[0].carByteCount, car.count)
        XCTAssertEqual(repos[0].displayName, "alice.test")

        XCTAssertEqual(try cache.load(did: "did:plc:test123"), car)

        try cache.delete(did: "did:plc:test123")
        XCTAssertTrue(try cache.cachedRepos().isEmpty)
        XCTAssertThrowsError(try cache.load(did: "did:plc:test123")) { error in
            guard case AppError.cache = error else {
                return XCTFail("expected .cache, got \(error)")
            }
        }
    }

    /// Indexes written before `carByteCount` existed must still decode (the
    /// field is optional), so an existing cache directory survives upgrades.
    func testOldFormatIndexWithoutByteCountDecodes() throws {
        // Manually write a pre-byte-count index (secondsSince1970 date, no
        // carByteCount key) next to a CAR file.
        let did = "did:plc:legacy"
        let car = try XCTUnwrap(TestFixtures.carData())
        try car.write(to: directory.appendingPathComponent("\(did).car"))
        let index = #"{"\#(did)":{"handle":"old.test","cachedAt":1700000000.5,"recordCount":2}}"#
        try Data(index.utf8).write(to: directory.appendingPathComponent("index.json"))

        let repos = try cache.cachedRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].did, did)
        XCTAssertEqual(repos[0].recordCount, 2)
        XCTAssertNil(repos[0].carByteCount)
        // A pre-history entry degrades to a single mirror, no growth.
        XCTAssertEqual(repos[0].mirrorCount, 1)
        XCTAssertNil(repos[0].sizeGrowthBytes)
    }

    func testOverwriteRefreshesInPlace() throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: "did:plc:same", handle: "one.test", car: car, recordCount: 2)
        try cache.save(did: "did:plc:same", handle: "two.test", car: car, recordCount: 5)

        let repos = try cache.cachedRepos()
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(repos[0].handle, "two.test")
        XCTAssertEqual(repos[0].recordCount, 5)
    }

    /// Every successful mirror appends a history snapshot, so the library can
    /// show repo growth over time. Snapshots are oldest-first; growth is the
    /// byte delta from the first to the latest sized mirror.
    func testHistoryAccumulatesAcrossMirrors() throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        // Three successive mirrors with growing sizes and record counts.
        try cache.save(did: "did:plc:grower", handle: nil, car: car, recordCount: 2)
        let car2 = try XCTUnwrap(Data(count: car.count + 4096))
        try cache.save(did: "did:plc:grower", handle: nil, car: car2, recordCount: 7)
        let car3 = try XCTUnwrap(Data(count: car2.count + 8192))
        try cache.save(did: "did:plc:grower", handle: nil, car: car3, recordCount: 12)

        let repos = try cache.cachedRepos()
        XCTAssertEqual(repos.count, 1)
        let repo = repos[0]
        XCTAssertEqual(repo.recordCount, 12)
        XCTAssertEqual(repo.carByteCount, car3.count)
        XCTAssertEqual(repo.mirrorCount, 3)
        XCTAssertEqual(repo.history.count, 3)
        // Oldest first, newest last.
        XCTAssertEqual(repo.history[0].carByteCount, car.count)
        XCTAssertEqual(repo.history[2].carByteCount, car3.count)
        XCTAssertEqual(repo.history[2].recordCount, 12)
        // Growth from the first to the latest sized mirror.
        XCTAssertEqual(repo.sizeGrowthBytes, car3.count - car.count)
    }

    func testListOrdersMostRecentFirst() throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: "did:plc:first", handle: nil, car: car, recordCount: 2)
        try cache.save(did: "did:plc:second", handle: nil, car: car, recordCount: 2)

        XCTAssertEqual(try cache.cachedRepos().map(\.did), ["did:plc:second", "did:plc:first"])
    }

    func testLoadMissingThrowsCacheError() {
        XCTAssertThrowsError(try cache.load(did: "did:plc:nope")) { error in
            guard case AppError.cache = error else {
                return XCTFail("expected .cache, got \(error)")
            }
        }
    }

    func testDeleteMissingIsNoop() {
        XCTAssertNoThrow(try cache.delete(did: "did:plc:nope"))
    }

    // MARK: resolved-names persistence

    func testStoreLoadNamesRoundTrip() throws {
        let repoDID = "did:plc:repo1"
        try cache.storeName("alice.bsky.social", forSubject: "did:plc:alice", inRepo: repoDID)
        try cache.storeName("bob.bsky.social", forSubject: "did:plc:bob", inRepo: repoDID)

        XCTAssertEqual(cache.loadNames(forRepo: repoDID), [
            "did:plc:alice": "alice.bsky.social",
            "did:plc:bob": "bob.bsky.social",
        ])
    }

    func testStoreNameMergesAcrossCalls() throws {
        let repoDID = "did:plc:repo2"
        try cache.storeName("a.bsky.social", forSubject: "did:plc:a", inRepo: repoDID)
        try cache.storeName("a.bsky.social", forSubject: "did:plc:a", inRepo: repoDID)
        XCTAssertEqual(cache.loadNames(forRepo: repoDID), ["did:plc:a": "a.bsky.social"])
    }

    /// People the latest mirror no longer references are pruned after a
    /// re-mirror, so a dropped like/follow/block doesn't keep showing its
    /// subject's handle ("shows people the repo dropped").
    func testPruneNamesKeepsReferencedDropsPruned() throws {
        let repoDID = "did:plc:repo-prune"
        try cache.storeName("alice.bsky.social", forSubject: "did:plc:alice", inRepo: repoDID)
        try cache.storeName("bob.bsky.social", forSubject: "did:plc:bob", inRepo: repoDID)

        // Re-mirror shows the repo still references Alice, but dropped Bob.
        try cache.pruneNames(forRepo: repoDID, referencing: ["did:plc:alice"])

        XCTAssertEqual(cache.loadNames(forRepo: repoDID), ["did:plc:alice": "alice.bsky.social"])
    }

    // MARK: resolved-entities persistence (starter-pack feeds)

    /// Feeds live in their own map so feed generators never share the people
    /// cache with accounts.
    func testEntitiesRoundTripSeparateFromNames() throws {
        let repoDID = "did:plc:repo-entities"
        try cache.storeName("alice.bsky.social", forSubject: "did:plc:alice", inRepo: repoDID)
        try cache.storeEntity("Great Feeds", forSubject: "did:plc:feedgen", inRepo: repoDID)

        XCTAssertEqual(cache.loadNames(forRepo: repoDID), ["did:plc:alice": "alice.bsky.social"])
        XCTAssertEqual(cache.loadEntities(forRepo: repoDID), ["did:plc:feedgen": "Great Feeds"])
    }

    func testPruneEntitiesKeepsReferencedDropsPruned() throws {
        let repoDID = "did:plc:repo-prune-entities"
        try cache.storeEntity("Keep", forSubject: "did:plc:keep", inRepo: repoDID)
        try cache.storeEntity("Drop", forSubject: "did:plc:drop", inRepo: repoDID)

        try cache.pruneEntities(forRepo: repoDID, referencing: ["did:plc:keep"])

        XCTAssertEqual(cache.loadEntities(forRepo: repoDID), ["did:plc:keep": "Keep"])
    }

    func testDeleteRemovesEntitiesToo() throws {
        let repoDID = "did:plc:repo-entity-delete"
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: repoDID, handle: "x.test", car: car, recordCount: 2)
        try cache.storeEntity("Feeds", forSubject: "did:plc:feed", inRepo: repoDID)
        XCTAssertFalse(cache.loadEntities(forRepo: repoDID).isEmpty)

        try cache.delete(did: repoDID)
        XCTAssertEqual(cache.loadEntities(forRepo: repoDID), [:])
    }

    func testPruneNamesWithNoChangesIsASafeNoop() throws {
        let repoDID = "did:plc:repo-keep"
        try cache.storeName("alice.bsky.social", forSubject: "did:plc:alice", inRepo: repoDID)
        try cache.pruneNames(forRepo: repoDID, referencing: ["did:plc:alice"])
        XCTAssertEqual(cache.loadNames(forRepo: repoDID), ["did:plc:alice": "alice.bsky.social"])
        // Missing repo + empty referenced set is a no-op, not an error.
        XCTAssertNoThrow(try cache.pruneNames(forRepo: "did:plc:never", referencing: []))
    }

    func testLoadNamesMissingOrCorruptIsEmpty() throws {
        // No file yet.
        XCTAssertEqual(cache.loadNames(forRepo: "did:plc:missing"), [:])
        // Corrupt file degrades to empty, not a crash.
        let url = directory.appendingPathComponent("did:plc:broken.names.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(cache.loadNames(forRepo: "did:plc:broken"), [:])
    }

    func testDeleteRemovesStoredNames() throws {
        let repoDID = "did:plc:repo-delete"
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: repoDID, handle: "x.test", car: car, recordCount: 2)
        try cache.storeName("c.bsky.social", forSubject: "did:plc:c", inRepo: repoDID)
        XCTAssertFalse(cache.loadNames(forRepo: repoDID).isEmpty)

        try cache.delete(did: repoDID)
        XCTAssertEqual(cache.loadNames(forRepo: repoDID), [:])
    }

    func testCacheErrorMessageIsReadable() {
        XCTAssertEqual(
            AppError.cache("disk full").userMessage,
            "Couldn't use the offline copy: disk full")
    }

    /// The milestone's demo, fully offline: save a CAR → list it → load it
    /// back → decode → browse collections and records. No transport, no
    /// network, no fake needed.
    func testOfflineBrowseEndToEnd() async throws {
        let car = try XCTUnwrap(TestFixtures.carData())
        try cache.save(did: "did:plc:test123", handle: "alice.test", car: car, recordCount: 2)

        let repos = try cache.cachedRepos()
        XCTAssertEqual(repos.first?.did, "did:plc:test123")

        let session = try AppSession(host: "https://example.invalid")
        let loaded = try cache.load(did: "did:plc:test123")
        let decoded = try await session.decodeCar(loaded)
        let repo = OfflineRepo(did: "did:plc:test123", recordCar: decoded)

        XCTAssertEqual(repo.collections, ["app.bsky.feed.post"])
        let posts = repo.records(in: "app.bsky.feed.post")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].value["text"]?.stringValue, "hello")
        XCTAssertEqual(posts[1].value["text"]?.stringValue, "world")
    }
}
