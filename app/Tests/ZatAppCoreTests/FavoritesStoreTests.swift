import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `FavoritesStore` — persist bookmarked records to disk,
/// round-trip the decoded value, order newest-first, toggle, remove. Every
/// test uses a throwaway directory and no network at all.
final class FavoritesStoreTests: XCTestCase {
    private var directory: URL!
    private var store: FavoritesStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosplorer-favorites-tests-\(UUID().uuidString)", isDirectory: true)
        store = FavoritesStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Whole-second timestamps round-trip exactly through the store's
    /// secondsSince1970 encoding; a live `Date()` would lose sub-second
    /// precision on the disk round trip and never compare equal.
    private func record(uri: String, text: String) -> FavoriteRecord {
        FavoriteRecord(
            uri: uri, cid: "bafy-cid-\(text)",
            value: ["text": .string(text), "n": 42],
            repoDid: "did:plc:repo1", repoName: "repo1.test",
            addedAt: Date(timeIntervalSince1970: 1_234_567_890))
    }

    func testAddFavoritesRoundTrip() throws {
        let favorite = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "hello")
        let saved = try store.add(
            uri: favorite.uri, cid: favorite.cid, value: favorite.value,
            repoDid: favorite.repoDid, repoName: favorite.repoName,
            addedAt: favorite.addedAt)

        XCTAssertEqual(saved, favorite)
        XCTAssertTrue(store.contains(uri: favorite.uri))
        XCTAssertEqual(store.favorites(), [favorite])
    }

    /// The decoded value is stored in full, so opening a favorite needs no
    /// network — even a deep body must round-trip exactly.
    func testValueRoundTripsExactly() throws {
        let value: ZatJSONValue = [
            "text": "deep",
            "embed": ["external": ["title": "T", "uri": "https://x.test"]],
            "tags": ["a", "b", "c"],
            "count": 12,
            "ratio": 0.5,
            "active": true,
            "nothing": nil,
        ]
        try store.add(
            uri: "at://did:plc:repo1/app.bsky.feed.post/9",
            cid: nil, value: value, repoDid: "did:plc:repo1", repoName: "r")
        XCTAssertEqual(store.favorites().first?.value, value)
        XCTAssertEqual(store.favorites().first?.value["embed"]?["external"]?["title"]?.stringValue, "T")
    }

    func testNewestFirstOrdering() throws {
        let a = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "oldest")
        let b = record(uri: "at://did:plc:repo1/app.bsky.feed.post/2", text: "middle")
        let c = record(uri: "at://did:plc:repo1/app.bsky.feed.post/3", text: "newest")
        try store.add(uri: a.uri, cid: a.cid, value: a.value, repoDid: a.repoDid, repoName: a.repoName, addedAt: Date(timeIntervalSince1970: 100))
        try store.add(uri: b.uri, cid: b.cid, value: b.value, repoDid: b.repoDid, repoName: b.repoName, addedAt: Date(timeIntervalSince1970: 300))
        try store.add(uri: c.uri, cid: c.cid, value: c.value, repoDid: c.repoDid, repoName: c.repoName, addedAt: Date(timeIntervalSince1970: 200))

        // Newest first, and the tie-breaking precision is sub-second.
        XCTAssertEqual(store.favorites().map(\.uri), [b.uri, c.uri, a.uri])
    }

    /// Re-adding the same URI refreshes it in place (one entry, new timestamp)
    /// instead of duplicating.
    func testReaddRefreshesInPlace() throws {
        let first = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "v1")
        let second = record(uri: first.uri, text: "v2")
        try store.add(uri: first.uri, cid: first.cid, value: first.value, repoDid: first.repoDid, repoName: first.repoName)
        try store.add(uri: second.uri, cid: second.cid, value: second.value, repoDid: second.repoDid, repoName: second.repoName)

        let all = store.favorites()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].value["text"]?.stringValue, "v2")
    }

    func testRemoveAndRemoveMissing() throws {
        let favorite = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "bye")
        try store.add(uri: favorite.uri, cid: favorite.cid, value: favorite.value, repoDid: favorite.repoDid, repoName: favorite.repoName)
        try store.remove(uri: favorite.uri)

        XCTAssertFalse(store.contains(uri: favorite.uri))
        XCTAssertTrue(store.favorites().isEmpty)
        // Removing something not present is a no-op, not an error.
        XCTAssertNoThrow(try store.remove(uri: "at://did:plc:repo1/app.bsky.feed.post/nope"))
    }

    func testToggleOnThenOff() throws {
        let favorite = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "flip")
        let nowFavorite = try store.toggle(
            uri: favorite.uri, cid: favorite.cid, value: favorite.value,
            repoDid: favorite.repoDid, repoName: favorite.repoName)
        XCTAssertTrue(nowFavorite)
        XCTAssertTrue(store.contains(uri: favorite.uri))

        let nowUnfavorited = try store.toggle(
            uri: favorite.uri, cid: favorite.cid, value: favorite.value,
            repoDid: favorite.repoDid, repoName: favorite.repoName)
        XCTAssertFalse(nowUnfavorited)
        XCTAssertFalse(store.contains(uri: favorite.uri))
        XCTAssertTrue(store.favorites().isEmpty)
    }

    /// A fresh store over the same directory sees what the previous one
    /// wrote — persistence, not just in-memory state.
    func testPersistenceAcrossInstances() throws {
        let favorite = record(uri: "at://did:plc:repo1/app.bsky.feed.post/1", text: "persist")
        try store.add(
            uri: favorite.uri, cid: favorite.cid, value: favorite.value,
            repoDid: favorite.repoDid, repoName: favorite.repoName,
            addedAt: favorite.addedAt)

        let reopened = FavoritesStore(directory: directory)
        XCTAssertEqual(reopened.favorites(), [favorite])
        XCTAssertTrue(reopened.contains(uri: favorite.uri))
    }

    /// A corrupt or missing favorites file degrades to empty, never a throw —
    /// same philosophy as the repo cache index.
    func testMissingOrCorruptFileIsEmpty() throws {
        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertFalse(store.contains(uri: "at://did:plc:repo1/app.bsky.feed.post/1"))

        let url = directory.appendingPathComponent("favorites.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(store.favorites().isEmpty)
        XCTAssertFalse(store.contains(uri: "at://did:plc:repo1/app.bsky.feed.post/1"))
    }
}
