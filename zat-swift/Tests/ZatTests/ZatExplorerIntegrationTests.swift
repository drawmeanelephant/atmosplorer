import XCTest

@testable import Zat

/// Live tests against real ATProto infrastructure. Gated behind
/// `ZAT_INTEGRATION=1` so the default `swift test` stays offline:
///
///     ZAT_INTEGRATION=1 swift test --filter ZatExplorerIntegrationTests
final class ZatExplorerIntegrationTests: XCTestCase {
    /// A minimal lexicon model, to exercise typed decoding end-to-end.
    private struct Post: Decodable {
        let text: String?
        let createdAt: String?
    }

    private func requireIntegration() throws {
        guard ProcessInfo.processInfo.environment["ZAT_INTEGRATION"] == "1" else {
            throw XCTSkip("set ZAT_INTEGRATION=1 to run live tests against real ATProto infrastructure")
        }
    }

    private func makeSession() throws -> ZatExplorer {
        try requireIntegration()
        return try ZatExplorer(host: "https://bsky.social")
    }

    func testCoreVersionMatchesZigCore() throws {
        try requireIntegration()
        XCTAssertFalse(ZatExplorer.coreVersion.isEmpty)
    }

    func testResolveIdentity() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")

        XCTAssertTrue(identity.did.hasPrefix("did:plc:"))
        XCTAssertEqual(identity.handle, "atproto.com")
        XCTAssertNotNil(identity.pds)
        XCTAssertNotNil(identity.pdsURL)
    }

    func testDescribeRepoListsCollections() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let description = try explorer.describeRepo(identity.did)

        XCTAssertEqual(description.did, identity.did)
        XCTAssertTrue(description.collections.contains("app.bsky.feed.post"))
    }

    func testListRecordsPageWithTypedModel() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let page = try explorer.listRecords(
            repo: identity.did,
            collection: "app.bsky.feed.post",
            limit: 5,
            as: Post.self
        )

        XCTAssertEqual(page.records.count, 5)
        for record in page.records {
            XCTAssertTrue(record.uri.hasPrefix("at://\(identity.did)/app.bsky.feed.post/"))
            XCTAssertNotNil(record.value.text)
            XCTAssertNotNil(record.value.createdAt)
        }
    }

    func testGetRecordRoundTripsAListedRecord() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let page = try explorer.listRecords(
            repo: identity.did,
            collection: "app.bsky.feed.post",
            limit: 1,
            as: Post.self
        )
        let listed = try XCTUnwrap(page.records.first)

        let fetched = try explorer.getRecord(at: listed.uri, as: Post.self)
        XCTAssertEqual(fetched.uri, listed.uri)
        XCTAssertEqual(fetched.value.text, listed.value.text)
    }

    func testGetRecordDecodesRawJSON() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let page = try explorer.listRecords(
            repo: identity.did,
            collection: "app.bsky.feed.post",
            limit: 1,
            as: Post.self
        )
        let listed = try XCTUnwrap(page.records.first)

        let fetched = try explorer.getRecord(at: listed.uri, as: ZatJSONValue.self)
        XCTAssertEqual(fetched.uri, listed.uri)
        XCTAssertEqual(fetched.value["text"]?.stringValue, listed.value.text)
        XCTAssertEqual(fetched.value["$type"]?.stringValue, "app.bsky.feed.post")
    }

    func testPdsDataSessionFetchesRepoCar() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let pds = try explorer.dataSession(for: identity)
        let car = try pds.fetchRepoCar(did: identity.did)

        // A CAR v1 starts with a varint header length followed by a
        // DAG-CBOR header; assert a plausible non-empty payload here.
        XCTAssertGreaterThan(car.count, 100)
    }

    func testFetchRepoCarRecordsDecodesRealRepo() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let pds = try explorer.dataSession(for: identity)
        let records = try pds.fetchRepoCarRecords(did: identity.did)

        XCTAssertFalse(records.records.isEmpty)
        for record in records.records {
            XCTAssertTrue(record.path.contains("/"), "record path should be collection/rkey")
            XCTAssertTrue(record.cid.hasPrefix("bafy"))
            XCTAssertEqual(record.value["$type"]?.stringValue, String(record.path.prefix(while: { $0 != "/" })))
        }
    }

    func testPagingWalksAtLeastTwoPages() throws {
        let explorer = try makeSession()
        let identity = try explorer.resolveIdentity("atproto.com")
        let firstPage = try explorer.listRecords(
            repo: identity.did,
            collection: "app.bsky.feed.like",
            limit: 5,
            as: ZatJSONValue.self
        )
        guard let cursor = firstPage.cursor, !firstPage.records.isEmpty else {
            throw XCTSkip("repo has fewer than two pages of likes; nothing to page through")
        }

        let secondPage = try explorer.listRecords(
            repo: identity.did,
            collection: "app.bsky.feed.like",
            limit: 5,
            cursor: cursor,
            as: ZatJSONValue.self
        )
        XCTAssertFalse(secondPage.records.isEmpty)
        XCTAssertNotEqual(firstPage.records.first?.uri, secondPage.records.first?.uri)
    }
}
