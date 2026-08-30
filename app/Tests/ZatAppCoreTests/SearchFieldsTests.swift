import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `SearchFields` — the $type-aware extractor that turns a
/// record body into weighted searchable text (the search counterpart of
/// `RecordContent`, which renders the preview).
final class SearchFieldsTests: XCTestCase {
    // MARK: posts

    func testPostBodyTextIsHighWeight() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.post",
            "text": "hello world",
        ])
        XCTAssertEqual(fields.kind, "app.bsky.feed.post")
        XCTAssertEqual(fields.text, [.init(text: "hello world", weight: .high)])
    }

    func testPostLinkCardWeightsTitleAndDescription() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.post",
            "text": "",
            "embed": ["external": [
                "title": "Some Site",
                "description": "A link card",
            ]],
        ])
        XCTAssertEqual(fields.text, [
            .init(text: "Some Site", weight: .medium),
            .init(text: "A link card", weight: .low),
        ])
    }

    func testPostImageAltsAreMediumWeight() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.post",
            "text": "look",
            "embed": ["images": [
                ["alt": "a cat"],
                ["alt": ""],
            ]],
        ])
        XCTAssertEqual(fields.text, [
            .init(text: "look", weight: .high),
            .init(text: "a cat", weight: .medium),
        ])
    }

    // MARK: named records (profiles, starter packs, lists, feed generators)

    func testProfileDisplayNameHighDescriptionMedium() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.actor.profile",
            "displayName": "Alice",
            "description": "Cozy corner",
        ])
        XCTAssertEqual(fields.text, [
            .init(text: "Alice", weight: .high),
            .init(text: "Cozy corner", weight: .medium),
        ])
    }

    func testStarterPackNameHighDescriptionMedium() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.graph.starterpack",
            "name": "Picks",
            "description": "books and tea",
        ])
        XCTAssertEqual(fields.text, [
            .init(text: "Picks", weight: .high),
            .init(text: "books and tea", weight: .medium),
        ])
    }

    func testFeedGeneratorUsesDisplayName() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.generator",
            "displayName": "Great Feeds",
            "description": "hand-picked",
        ])
        XCTAssertEqual(fields.text, [
            .init(text: "Great Feeds", weight: .high),
            .init(text: "hand-picked", weight: .medium),
        ])
    }

    // MARK: interactions (who did I like / follow / block)

    func testLikeExtractsSubjectAuthorityMedium() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.like",
            "subject": ["uri": "at://alice.bsky.social/app.bsky.feed.post/abc", "cid": "bafy"],
        ])
        XCTAssertEqual(fields.text, [.init(text: "alice.bsky.social", weight: .medium)])
    }

    func testFollowExtractsSubjectDIDMedium() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.graph.follow",
            "subject": ["did": "did:plc:bob"],
        ])
        XCTAssertEqual(fields.text, [.init(text: "did:plc:bob", weight: .medium)])
    }

    func testBlockPlainStringSubjectMedium() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.graph.block",
            "subject": "did:plc:mallory",
        ])
        XCTAssertEqual(fields.text, [.init(text: "did:plc:mallory", weight: .medium)])
    }

    // MARK: fallback

    func testUnknownLexiconKeepsKindAndTextHigh() {
        let fields = SearchFields(value: [
            "$type": "com.example.widget",
            "text": "widget text",
            "title": "Widget",
        ])
        // Unknown kinds fall through to the generic extractor, but the raw
        // $type is kept so kind filtering still works on new lexicons.
        XCTAssertEqual(fields.kind, "com.example.widget")
        XCTAssertEqual(fields.text, [
            .init(text: "widget text", weight: .high),
            .init(text: "Widget", weight: .high),
        ])
    }

    func testNoTypeFallsBackToGenericWithNilKind() {
        let fields = SearchFields(value: ["name": "Widget", "description": "whatever"])
        XCTAssertNil(fields.kind)
        XCTAssertEqual(fields.text, [
            .init(text: "Widget", weight: .high),
            .init(text: "whatever", weight: .high),
        ])
    }

    func testEmptyRecordHasNoSearchableText() {
        let fields = SearchFields(value: ["$type": "app.bsky.feed.post"])
        XCTAssertEqual(fields.text, [])
    }

    // MARK: date

    func testCreatedAtExtractedForRecency() {
        let fields = SearchFields(value: [
            "$type": "app.bsky.feed.post",
            "text": "hi",
            "createdAt": "2026-08-28T12:00:00Z",
        ])
        XCTAssertEqual(fields.date, "2026-08-28T12:00:00Z")
        XCTAssertNil(SearchFields(value: ["$type": "app.bsky.feed.post", "text": "hi"]).date)
    }
}
