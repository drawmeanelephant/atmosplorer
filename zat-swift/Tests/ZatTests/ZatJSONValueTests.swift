import XCTest

@testable import Zat

final class ZatJSONValueTests: XCTestCase {
    func testDecodesAndNavigatesARecordBody() throws {
        let json = #"{"text":"hi","count":42,"ratio":1.5,"ok":true,"nope":null,"tags":["a","b"],"embed":{"external":{"title":"Tangled"}}}"#
        let value = try JSONDecoder().decode(ZatJSONValue.self, from: Data(json.utf8))

        XCTAssertEqual(value["text"]?.stringValue, "hi")
        XCTAssertEqual(value["count"]?.intValue, 42)
        XCTAssertEqual(value["ratio"]?.doubleValue, 1.5)
        XCTAssertEqual(value["ok"]?.boolValue, true)
        XCTAssertTrue(value["nope"]?.isNull ?? false)
        XCTAssertEqual(value["tags"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["tags"]?[1]?.stringValue, "b")
        XCTAssertEqual(value["embed"]?["external"]?["title"]?.stringValue, "Tangled")
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["text"]?["not-an-object"])
    }

    func testEncodeDecodeRoundTrip() throws {
        let original: ZatJSONValue = [
            "text": "hi",
            "n": 7,
            "ok": false,
            "nested": ["x": nil, "list": [1, "two"]],
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ZatJSONValue.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testLiterals() {
        let value: ZatJSONValue = "hello"
        XCTAssertEqual(value, .string("hello"))
        XCTAssertEqual(ZatJSONValue(3), .int(3))
        XCTAssertEqual(ZatJSONValue(true), .bool(true))
        XCTAssertEqual(ZatJSONValue(nil), .null)
    }

    func testRecordEnvelopeDecodesUriCidAndValue() throws {
        let json = #"{"uri":"at://did:plc:abc/app.bsky.feed.post/3jz","cid":"bafyabc","value":{"text":"hi"}}"#
        let envelope = try JSONDecoder().decode(RecordEnvelope<ZatJSONValue>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.uri, "at://did:plc:abc/app.bsky.feed.post/3jz")
        XCTAssertEqual(envelope.cid, "bafyabc")
        XCTAssertEqual(envelope.value["text"]?.stringValue, "hi")
    }

    func testRecordEnvelopeHandlesMissingCid() throws {
        let json = #"{"uri":"at://did:plc:abc/app.bsky.feed.post/3jz","value":{"text":"hi"}}"#
        let envelope = try JSONDecoder().decode(RecordEnvelope<ZatJSONValue>.self, from: Data(json.utf8))
        XCTAssertNil(envelope.cid)
    }

    func testRecordPageEnvelopeDecodesRecordsAndCursor() throws {
        let json = #"{"records":[{"uri":"at://did:plc:abc/app.bsky.feed.post/1","value":{"text":"a"}},{"uri":"at://did:plc:abc/app.bsky.feed.post/2","value":{"text":"b"}}],"cursor":"2"}"#
        let envelope = try JSONDecoder().decode(RecordPageEnvelope<ZatJSONValue>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.records.count, 2)
        XCTAssertEqual(envelope.records[0].value["text"]?.stringValue, "a")
        XCTAssertEqual(envelope.cursor, "2")
    }
}
