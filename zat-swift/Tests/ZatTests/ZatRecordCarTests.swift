import XCTest

@testable import Zat

/// Offline tests for `ZatExplorer.recordCar(from:)` — decoding a repo CAR's
/// commit block, MST walk, and record blocks entirely on-device.
///
/// The fixture is the deterministic output of the zat core's
/// `zig build gen-car-fixture` (a 2-record `app.bsky.feed.post` repo),
/// base64-encoded. Regenerate with:
///
///     (cd DEVKITS/zat-main && zig build gen-car-fixture | base64 | tr -d '\n')
final class ZatRecordCarTests: XCTestCase {
    private static let fixtureBase64 =
        "OqJlcm9vdHOB2CpYJQABcRIg8whTzJcN1ei6RLX07hC14U7XFzMFxYVmxXTTRl90411ndmVyc2lvbgGNAQFxEiDzCFPMlw3V6LpEtfTuELXhTtcXMwXFhWbFdNNGX3TjXaVjZGlkb2RpZDpwbGM6dGVzdDEyM2NyZXZsM2syYWJjMDAwMDAwY3NpZ0dmYWtlc2lnZGRhdGHYKlglAAFxEiCMNa73ajUWU7QTJmr+BeTM/062QMAWEcJtBImnf/0b82d2ZXJzaW9uA0kBcRIgS+2EbICFfTWwoYB9wcWn6g3+MWYzCw/jghmb4KSr1MiiZHRleHRlaGVsbG9lJHR5cGVyYXBwLmJza3kuZmVlZC5wb3N0SQFxEiABiUX+4QelZaHiXXoGb2MRTeF+odjX/bTUiC1J2zyL9aJkdGV4dGV3b3JsZGUkdHlwZXJhcHAuYnNreS5mZWVkLnBvc3StAQFxEiCMNa73ajUWU7QTJmr+BeTM/062QMAWEcJtBImnf/0b86JhZYKkYWtXYXBwLmJza3kuZmVlZC5wb3N0LzNqejFhcABhdPZhdtgqWCUAAXESIEvthGyAhX01sKGAfcHFp+oN/jFmMwsP44IZm+Ckq9TIpGFrQTJhcBZhdPZhdtgqWCUAAXESIAGJRf7hB6VloeJdegZvYxFN4X6h2Nf9tNSILUnbPIv1YWz2"

    private func fixtureData() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.fixtureBase64))
    }

    func testDecodesEveryRecordOffline() throws {
        let explorer = try ZatExplorer(host: "https://example.invalid")
        let car = try explorer.recordCar(from: fixtureData())

        XCTAssertEqual(car.records.count, 2)

        // MST key order: app.bsky.feed.like would sort first, but the fixture
        // has only feed.post records, so key order is 3jz1 then 3jz2.
        XCTAssertEqual(car.records[0].path, "app.bsky.feed.post/3jz1")
        XCTAssertEqual(car.records[0].value["text"]?.stringValue, "hello")
        XCTAssertEqual(car.records[0].value["$type"]?.stringValue, "app.bsky.feed.post")
        XCTAssertTrue(car.records[0].cid.hasPrefix("bafy"))

        XCTAssertEqual(car.records[1].path, "app.bsky.feed.post/3jz2")
        XCTAssertEqual(car.records[1].value["text"]?.stringValue, "world")
        XCTAssertTrue(car.records[1].cid.hasPrefix("bafy"))
        XCTAssertNotEqual(car.records[0].cid, car.records[1].cid)
    }

    func testDecodesIntoTypedModels() throws {
        let explorer = try ZatExplorer(host: "https://example.invalid")

        struct Post: Decodable, Equatable {
            let text: String
            let type: String

            enum CodingKeys: String, CodingKey {
                case text
                case type = "$type"
            }
        }
        let car = try explorer.recordCar(from: fixtureData())
        let posts = try car.records.map { record in
            try record.value.decode(as: Post.self)
        }
        XCTAssertEqual(posts, [
            Post(text: "hello", type: "app.bsky.feed.post"),
            Post(text: "world", type: "app.bsky.feed.post"),
        ])
    }

    func testRejectsGarbageBytes() throws {
        let explorer = try ZatExplorer(host: "https://example.invalid")
        XCTAssertThrowsError(try explorer.recordCar(from: Data("not a car".utf8))) { error in
            XCTAssertEqual(error as? ZatError, .invalidResponse)
        }
    }
}
