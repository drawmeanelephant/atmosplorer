import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `LocalSearch` — the tiered token matcher (exact >
/// prefix > substring), weight-aware scoring, kind filtering, and recency
/// tiebreaking. No network, no views.
final class LocalSearchTests: XCTestCase {
    /// A post entry with a single high-weight body field.
    private func post(_ path: String, text: String, date: String? = nil) -> SearchIndexEntry {
        var value: [String: ZatJSONValue] = ["$type": "app.bsky.feed.post", "text": .string(text)]
        if let date { value["createdAt"] = .string(date) }
        return SearchIndexEntry(path: path, cid: "bafy-\(path)", fields: SearchFields(value: .object(value)))
    }

    /// An entry with a medium-weight field (e.g. a like's subject).
    private func like(_ path: String, subject: String) -> SearchIndexEntry {
        SearchIndexEntry(
            path: path, cid: "bafy-\(path)",
            fields: SearchFields(value: [
                "$type": "app.bsky.feed.like",
                "subject": ["uri": .string("at://\(subject)/app.bsky.feed.post/abc")],
            ]))
    }

    // MARK: tokenizer

    func testTokenizerSplitsCaseAndPunctuation() {
        XCTAssertEqual(LocalSearch.tokens(in: "Hello, World!"), ["hello", "world"])
        XCTAssertEqual(LocalSearch.tokens(in: "ATProto/atproto"), ["atproto", "atproto"])
        XCTAssertEqual(LocalSearch.tokens(in: "café ☕ 123"), ["café", "123"])
        XCTAssertEqual(LocalSearch.tokens(in: "   "), [])
    }

    // MARK: tiers

    func testExactBeatsPrefixBeatsSubstring() {
        let exact = post("app.bsky.feed.post/1", text: "atl")
        let prefix = post("app.bsky.feed.post/2", text: "atlas mountains")
        // A true substring-only match: "subatlantic" contains "atl" but
        // doesn't start with it, so it can't win the prefix tier.
        let substring = post("app.bsky.feed.post/3", text: "the subatlantic current")

        let results = LocalSearch.results(for: "atl", in: [substring, exact, prefix])
        XCTAssertEqual(results.map { $0.entry.path }, [
            "app.bsky.feed.post/1",
            "app.bsky.feed.post/2",
            "app.bsky.feed.post/3",
        ])
        XCTAssertGreaterThan(results[0].score, results[1].score)
        XCTAssertGreaterThan(results[1].score, results[2].score)
    }

    func testHigherWeightWinsWithinTier() {
        // Same tier (prefix): a prefix match in the high-weight body beats a
        // prefix match in a low-weight link description.
        let body = post("app.bsky.feed.post/1", text: "atproto is neat")
        let linkDescription = SearchIndexEntry(
            path: "app.bsky.feed.post/2", cid: "bafy-2",
            fields: SearchFields(value: [
                "$type": "app.bsky.feed.post",
                "text": "",
                "embed": ["external": ["title": "x", "description": "an atproto overview"]],
            ]))

        let results = LocalSearch.results(for: "atpro", in: [linkDescription, body])
        XCTAssertEqual(results.map { $0.entry.path }, [
            "app.bsky.feed.post/1",
            "app.bsky.feed.post/2",
        ])
    }

    // MARK: query semantics

    func testEveryQueryTokenMustMatch() {
        let both = post("app.bsky.feed.post/1", text: "swift mac app")
        let one = post("app.bsky.feed.post/2", text: "swift language")

        let results = LocalSearch.results(for: "swift mac", in: [one, both])
        XCTAssertEqual(results.map { $0.entry.path }, ["app.bsky.feed.post/1"])
    }

    func testEmptyOrWhitespaceQueryReturnsNoResults() {
        let entries = [post("app.bsky.feed.post/1", text: "hello world")]
        XCTAssertTrue(LocalSearch.results(for: "", in: entries).isEmpty)
        XCTAssertTrue(LocalSearch.results(for: "   ", in: entries).isEmpty)
    }

    func testNoMatchesReturnsEmpty() {
        let entries = [post("app.bsky.feed.post/1", text: "hello world")]
        XCTAssertTrue(LocalSearch.results(for: "goodbye", in: entries).isEmpty)
    }

    // MARK: kind filter

    func testKindFilterRestrictsResults() {
        let entries = [
            post("app.bsky.feed.post/1", text: "swift"),
            like("app.bsky.feed.like/2", subject: "swift.bsky.social"),
        ]
        let options = LocalSearch.Options(kinds: ["app.bsky.feed.post"])
        let results = LocalSearch.results(for: "swift", in: entries, options: options)
        XCTAssertEqual(results.map { $0.entry.path }, ["app.bsky.feed.post/1"])

        // Nil-kind records can't prove membership in a filtered query.
        let noType = SearchIndexEntry(
            path: "com.example.widget/3", cid: "bafy-3",
            fields: SearchFields(value: ["text": "swift"]))
        let filtered = LocalSearch.results(
            for: "swift", in: [noType], options: LocalSearch.Options(kinds: ["com.example.widget"]))
        XCTAssertTrue(filtered.isEmpty)
    }

    // MARK: ordering

    func testNewerRecordWinsScoreTiebreak() {
        let older = post("app.bsky.feed.post/1", text: "atproto", date: "2026-01-01T00:00:00Z")
        let newer = post("app.bsky.feed.post/2", text: "atproto", date: "2026-08-01T00:00:00Z")
        let noDate = post("app.bsky.feed.post/3", text: "atproto")

        let results = LocalSearch.results(for: "atproto", in: [noDate, older, newer])
        XCTAssertEqual(results.map { $0.entry.path }, [
            "app.bsky.feed.post/2",
            "app.bsky.feed.post/1",
            "app.bsky.feed.post/3",
        ])
    }

    func testFullTiebreakFallsBackToPathOrder() {
        let a = post("app.bsky.feed.post/a", text: "atproto")
        let b = post("app.bsky.feed.post/b", text: "atproto")
        let results = LocalSearch.results(for: "atproto", in: [b, a])
        XCTAssertEqual(results.map { $0.entry.path }, ["app.bsky.feed.post/a", "app.bsky.feed.post/b"])
    }

    func testLimitCapsResults() {
        let entries = [
            post("app.bsky.feed.post/1", text: "atproto"),
            post("app.bsky.feed.post/2", text: "atproto"),
            post("app.bsky.feed.post/3", text: "atproto"),
        ]
        let results = LocalSearch.results(
            for: "atproto", in: entries, options: LocalSearch.Options(limit: 2))
        XCTAssertEqual(results.count, 2)
    }

    func testCollectionDerivedFromPath() {
        let entry = post("app.bsky.feed.post/3jz", text: "hello")
        XCTAssertEqual(entry.collection, "app.bsky.feed.post")
    }
}
