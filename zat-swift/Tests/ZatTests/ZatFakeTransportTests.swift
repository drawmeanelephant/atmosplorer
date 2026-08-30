import XCTest

@testable import Zat

/// Deterministic tests over the scripted transport — no network at all.
final class ZatFakeTransportTests: XCTestCase {
    func testPagingThroughAFakeTransport() throws {
        let fake = try ZatFakeTransport()
        try fake.queue(
            status: 200,
            body: #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/1","value":{"text":"a"}}],"cursor":"t2"}"#
        )
        try fake.queue(
            status: 200,
            body: #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/2","value":{"text":"b"}}]}"#
        )

        let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)
        let firstPage = try explorer.listRecords(
            repo: "did:plc:abc", collection: "app.bsky.feed.post", as: ZatJSONValue.self)
        XCTAssertEqual(firstPage.records.count, 1)
        XCTAssertEqual(firstPage.records.first?.value["text"]?.stringValue, "a")
        XCTAssertEqual(firstPage.cursor, "t2")

        let secondPage = try explorer.listRecords(
            repo: "did:plc:abc", collection: "app.bsky.feed.post",
            cursor: firstPage.cursor, as: ZatJSONValue.self)
        XCTAssertEqual(secondPage.records.count, 1)
        XCTAssertNil(secondPage.cursor)
        XCTAssertEqual(fake.requestCount, 2)

        // URLs are built and percent-encoded exactly as the C layer promises
        XCTAssertEqual(
            try fake.lastURL(),
            "https://fake.test/xrpc/com.atproto.repo.listRecords"
                + "?repo=did%3Aplc%3Aabc&collection=app.bsky.feed.post&cursor=t2"
        )
    }

    func testErrorEnvelopeSurfacesWithDetails() throws {
        let fake = try ZatFakeTransport()
        try fake.queue(status: 400, body: #"{"error":"InvalidRequest","message":"bad rkey"}"#)
        let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)

        XCTAssertThrowsError(
            try explorer.getRecord(at: "at://did:plc:abc/app.bsky.feed.post/3jz", as: ZatJSONValue.self)
        ) { error in
            guard let xrpc = error as? ZatXrpcError else {
                return XCTFail("expected ZatXrpcError, got \(error)")
            }
            XCTAssertEqual(xrpc.code, .invalidResponse)
            XCTAssertEqual(xrpc.details.httpStatus, 400)
            XCTAssertEqual(xrpc.details.errorName, "InvalidRequest")
            XCTAssertEqual(xrpc.details.message, "bad rkey")
            XCTAssertNil(xrpc.details.retryAfterSeconds)
            XCTAssertEqual(xrpc.errorDescription, "bad rkey")
        }
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testRateLimitEnvelopeAfterRetriesExhausted() throws {
        let fake = try ZatFakeTransport()
        // retry-after 0 → the checked path retries instantly; three 429s
        // exhaust the 3-attempt policy and the final envelope surfaces
        let envelope = #"{"error":"RateLimitExceeded","message":"slow down"}"#
        try fake.queue(status: 429, body: envelope, retryAfter: 0)
        try fake.queue(status: 429, body: envelope, retryAfter: 0)
        try fake.queue(status: 429, body: envelope, retryAfter: 0)
        let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)

        XCTAssertThrowsError(try explorer.describeRepo("did:plc:abc")) { error in
            guard let xrpc = error as? ZatXrpcError else {
                return XCTFail("expected ZatXrpcError, got \(error)")
            }
            XCTAssertEqual(xrpc.details.httpStatus, 429)
            XCTAssertEqual(xrpc.details.errorName, "RateLimitExceeded")
            XCTAssertEqual(xrpc.details.message, "slow down")
            XCTAssertEqual(xrpc.details.retryAfterSeconds, 0)
        }
        XCTAssertEqual(fake.requestCount, 3)
    }

    func testRateLimitRetryHappensWithoutSleeping() throws {
        let fake = try ZatFakeTransport()
        // retry-after 0 → the retry path runs instantly, no wall-clock delay
        try fake.queue(status: 429, body: "{}", retryAfter: 0)
        try fake.queue(status: 200, body: #"{"did":"did:plc:abc","collections":["app.bsky.feed.post"]}"#)
        let explorer = try ZatExplorer(host: "https://fake.test", fakeTransport: fake)

        let description = try explorer.describeRepo("did:plc:abc")
        XCTAssertEqual(description.did, "did:plc:abc")
        XCTAssertEqual(description.collections, ["app.bsky.feed.post"])
        XCTAssertEqual(fake.requestCount, 2)
    }

    func testLastURLBeforeAnyRequestThrows() throws {
        let fake = try ZatFakeTransport()
        XCTAssertThrowsError(try fake.lastURL()) { error in
            XCTAssertEqual(error as? ZatError, .invalidArgument)
        }
    }
}
