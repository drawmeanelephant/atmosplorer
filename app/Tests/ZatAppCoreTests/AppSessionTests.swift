import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for the app core: the async session bridge, the error
/// mapping, and offline CAR decoding. All XRPC traffic is scripted with
/// `ZatFakeTransport`; identity resolution is intentionally not exercised
/// here because it uses the network even with a fake (mirroring the
/// wrapper's own tests).
final class AppSessionTests: XCTestCase {
    private func fakeSession() throws -> (AppSession, ZatFakeTransport) {
        let fake = try ZatFakeTransport()
        let session = try AppSession(host: "https://fake.test", fakeTransport: fake)
        return (session, fake)
    }

    // MARK: - session bridge

    func testDescribeAndListRecordsRoundTrip() async throws {
        let (session, fake) = try fakeSession()
        try fake.queue(status: 200, body: #"{"did":"did:plc:abc","collections":["app.bsky.feed.post","app.bsky.feed.like"]}"#)
        try fake.queue(status: 200, body: #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/3jz1","cid":"bafy1","value":{"text":"hi","$type":"app.bsky.feed.post"}}],"cursor":null}"#)

        let description = try await session.describeRepo("did:plc:abc")
        XCTAssertEqual(description.did, "did:plc:abc")
        XCTAssertEqual(description.collections, ["app.bsky.feed.post", "app.bsky.feed.like"])

        let page = try await session.listRecords(
            repo: description.did, collection: "app.bsky.feed.post")
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records[0].uri, "at://did:plc:abc/app.bsky.feed.post/3jz1")
        XCTAssertEqual(page.records[0].value["text"]?.stringValue, "hi")
        XCTAssertNil(page.cursor)
        XCTAssertEqual(fake.requestCount, 2)
    }

    func testPagingFollowsCursor() async throws {
        let (session, fake) = try fakeSession()
        try fake.queue(status: 200, body: #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/3jz1","value":{"text":"one"}}],"cursor":"t2"}"#)
        try fake.queue(status: 200, body: #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/3jz2","value":{"text":"two"}}],"cursor":null}"#)

        let first = try await session.listRecords(repo: "did:plc:abc", collection: "app.bsky.feed.post")
        XCTAssertEqual(first.cursor, "t2")

        let second = try await session.listRecords(
            repo: "did:plc:abc", collection: "app.bsky.feed.post", cursor: first.cursor)
        XCTAssertEqual(second.records.map(\.uri), ["at://did:plc:abc/app.bsky.feed.post/3jz2"])
        XCTAssertNil(second.cursor)

        XCTAssertEqual(fake.requestCount, 2)
        XCTAssertTrue(try fake.lastURL().contains("cursor=t2"))
    }

    func testServerEnvelopeSurfacesAsAppError() async throws {
        let (session, fake) = try fakeSession()
        try fake.queue(status: 400, body: #"{"error":"InvalidRequest","message":"bad rkey"}"#)

        do {
            _ = try await session.describeRepo("did:plc:abc")
            XCTFail("expected the 400 to throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .server(message: "bad rkey", status: 400))
            XCTAssertEqual(error.userMessage, "bad rkey (HTTP 400)")
        }
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testRateLimitSurfacesAfterRetriesExhausted() async throws {
        let (session, fake) = try fakeSession()
        // Three 429s with retry-after 0: the checked path retries twice with
        // no sleeping, then surfaces the final envelope.
        let envelope = #"{"error":"RateLimitExceeded","message":"slow down"}"#
        try fake.queue(status: 429, body: envelope, retryAfter: 0)
        try fake.queue(status: 429, body: envelope, retryAfter: 0)
        try fake.queue(status: 429, body: envelope, retryAfter: 0)

        do {
            _ = try await session.describeRepo("did:plc:abc")
            XCTFail("expected the 429s to throw")
        } catch let error as AppError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 0))
            XCTAssertTrue(error.userMessage.contains("Rate limited"))
        }
        XCTAssertEqual(fake.requestCount, 3)
    }

    // MARK: - offline CAR decoding

    func testDecodeCarOffline() async throws {
        // No fake needed: decodeCar never touches the network.
        let session = try AppSession(host: "https://example.invalid")
        let car = try await session.decodeCar(try XCTUnwrap(TestFixtures.carData()))

        XCTAssertEqual(car.records.count, 2)
        XCTAssertEqual(car.records[0].path, "app.bsky.feed.post/3jz1")
        XCTAssertEqual(car.records[0].value["text"]?.stringValue, "hello")
        XCTAssertEqual(car.records[0].value["$type"]?.stringValue, "app.bsky.feed.post")
        XCTAssertTrue(car.records[0].cid.hasPrefix("bafy"))
        XCTAssertEqual(car.records[1].path, "app.bsky.feed.post/3jz2")
        XCTAssertEqual(car.records[1].value["text"]?.stringValue, "world")
    }

    // MARK: - error mapping

    func testDataSessionRequiresPds() {
        let identity = ZatIdentity(did: "did:plc:abc", handle: nil, pds: nil)
        XCTAssertThrowsError(try AppSession.dataSession(for: identity)) { error in
            XCTAssertEqual(error as? AppError, .missingPds)
        }
    }

    func testMapsPlainWrapperErrors() {
        XCTAssertEqual(AppError.from(ZatError.invalidIdentifier), .invalidIdentifier(""))
        XCTAssertEqual(AppError.from(ZatError.missingPds), .missingPds)
        XCTAssertEqual(AppError.from(ZatError.network), .network)
        XCTAssertEqual(AppError.from(ZatError.unexpected), .unexpected)
    }

    func testUserMessagesAreHumanReadable() {
        XCTAssertTrue(AppError.invalidIdentifier("nope").userMessage.contains("handle or DID"))
        XCTAssertEqual(AppError.server(message: "bad", status: 400).userMessage, "bad (HTTP 400)")
        XCTAssertEqual(AppError.rateLimited(retryAfter: 5).userMessage, "Rate limited. Try again in 5 seconds.")
        XCTAssertEqual(AppError.rateLimited(retryAfter: nil).userMessage, "Rate limited. Try again in a moment.")
        XCTAssertEqual(AppError.network.userMessage, "Couldn't reach the server. Check your connection and try again.")
        XCTAssertEqual(AppError.unexpected.userMessage, "Something unexpected went wrong.")
    }
}
