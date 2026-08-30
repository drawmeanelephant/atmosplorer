import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `OfflineRepo` — grouping a decoded CAR's records into
/// collections and per-collection lists, with at:// URIs synthesized from the
/// DID + MST path.
final class OfflineRepoTests: XCTestCase {
    func testDecodedFixtureGroupsIntoCollections() async throws {
        let session = try AppSession(host: "https://example.invalid")
        let car = try await session.decodeCar(try XCTUnwrap(TestFixtures.carData()))
        let repo = OfflineRepo(did: "did:plc:test123", recordCar: car)

        XCTAssertEqual(repo.recordCount, 2)
        XCTAssertEqual(repo.collections, ["app.bsky.feed.post"])

        let posts = repo.records(in: "app.bsky.feed.post")
        XCTAssertEqual(posts.map(\.uri), [
            "at://did:plc:test123/app.bsky.feed.post/3jz1",
            "at://did:plc:test123/app.bsky.feed.post/3jz2",
        ])
        XCTAssertEqual(posts[0].value["text"]?.stringValue, "hello")
        XCTAssertEqual(posts[1].value["text"]?.stringValue, "world")
        XCTAssertTrue(try XCTUnwrap(posts[0].cid).hasPrefix("bafy"))
        XCTAssertNotEqual(posts[0].cid, posts[1].cid)
    }

    func testGroupsAcrossCollectionsSorted() {
        let car = ZatRecordCar(records: [
            ZatCarRecord(path: "app.bsky.feed.like/3jz9", cid: "bafy-like", value: ["subject": "x"]),
            ZatCarRecord(path: "app.bsky.feed.post/3jz2", cid: "bafy-b", value: ["text": "world"]),
            ZatCarRecord(path: "app.bsky.feed.post/3jz1", cid: "bafy-a", value: ["text": "hello"]),
        ])
        let repo = OfflineRepo(did: "did:plc:x", recordCar: car)

        XCTAssertEqual(repo.collections, ["app.bsky.feed.like", "app.bsky.feed.post"])
        XCTAssertEqual(repo.records(in: "app.bsky.feed.post").map(\.uri), [
            "at://did:plc:x/app.bsky.feed.post/3jz1",
            "at://did:plc:x/app.bsky.feed.post/3jz2",
        ])
        XCTAssertEqual(repo.records(in: "app.bsky.feed.like").count, 1)
        XCTAssertTrue(repo.records(in: "app.bsky.feed.none").isEmpty)
    }

    func testCollectionAndRkeyParsing() {
        XCTAssertEqual(OfflineRepo.collection(of: "app.bsky.feed.post/3jz1"), "app.bsky.feed.post")
        XCTAssertEqual(OfflineRepo.rkey(of: "app.bsky.feed.post/3jz1"), "3jz1")
        XCTAssertEqual(OfflineRepo.collection(of: "not-a-path"), "not-a-path")
    }
}
