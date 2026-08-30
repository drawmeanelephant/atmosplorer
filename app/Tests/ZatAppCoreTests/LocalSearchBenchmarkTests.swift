import XCTest
import Zat
@testable import ZatAppCore

/// Wall-clock budget for the search hot path.
///
/// `LocalSearch` is the per-keystroke bottleneck of the offline search UI:
/// every settled query rescans the repo's whole index. These tests generate a
/// deterministic, realistic-shaped synthetic repo at the design-doc scale
/// (~275k records for a busy account) and time the scoring so the debounce
/// and any memoization stay grounded in numbers. The assertions are generous
/// ceilings — CI-safe against noise, but a regression like an accidental
/// O(n²) matching loop or a per-query full-file reread blows straight through
/// them.
final class LocalSearchBenchmarkTests: XCTestCase {
    // MARK: - synthetic corpus

    /// A realistic mix: ~60% posts (with `createdAt` for recency), plus
    /// likes, follows, profiles, and starter packs. A fixed share of posts
    /// carry a common token ("atproto") so common queries match many records.
    /// Fully deterministic — the RNG is a fixed-seed LCG.
    private func corpus(count: Int) -> [SearchIndexEntry] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }

        let vocab = [
            "protocol", "offline", "search", "swift", "mac", "index", "mirror",
            "car", "blue", "sky", "ocean", "atmosphere", "weather", "feed",
            "repo", "record", "handle", "did", "client", "core",
        ]
        let kinds = [
            "app.bsky.feed.post", "app.bsky.feed.post", "app.bsky.feed.post",
            "app.bsky.feed.like", "app.bsky.graph.follow",
            "app.bsky.actor.profile", "app.bsky.graph.starterpack",
        ]
        let handles = ["alice.bsky.social", "bob.test", "carol.example", "dave.net"]

        var entries: [SearchIndexEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let kind = kinds[pick(kinds.count)]
            let path = "\(kind)/3jz\(i)"
            let cid = "bafyreibc\(i)"
            switch kind {
            case "app.bsky.feed.post":
                var words = (0..<(6 + pick(5))).map { _ in vocab[pick(vocab.count)] }
                if pick(20) == 0 { words[0] = "atproto" }  // ~5% carry the common token
                entries.append(SearchIndexEntry(path: path, cid: cid, fields: SearchFields(value: [
                    "$type": "app.bsky.feed.post",
                    "text": .string(words.joined(separator: " ")),
                    "createdAt": .string("2026-0\(1 + pick(8))-1\(pick(9))T12:00:00Z"),
                ])))
            case "app.bsky.feed.like":
                entries.append(SearchIndexEntry(path: path, cid: cid, fields: SearchFields(value: [
                    "$type": "app.bsky.feed.like",
                    "subject": [
                        "uri": .string("at://\(handles[pick(handles.count)])/app.bsky.feed.post/3jz\(i)"),
                    ],
                ])))
            case "app.bsky.graph.follow":
                entries.append(SearchIndexEntry(path: path, cid: cid, fields: SearchFields(value: [
                    "$type": "app.bsky.graph.follow",
                    "subject": ["did": .string("did:plc:follow\(i)")],
                ])))
            case "app.bsky.actor.profile":
                entries.append(SearchIndexEntry(path: path, cid: cid, fields: SearchFields(value: [
                    "$type": "app.bsky.actor.profile",
                    "displayName": .string("User \(i)"),
                    "description": .string("Collector of \(vocab[pick(vocab.count)])"),
                ])))
            default:  // starter pack
                entries.append(SearchIndexEntry(path: path, cid: cid, fields: SearchFields(value: [
                    "$type": "app.bsky.graph.starterpack",
                    "name": .string("Pack \(i)"),
                    "description": .string("Hand-picked \(vocab[pick(vocab.count)]) feeds"),
                ])))
            }
        }
        return entries
    }

    // MARK: - timing

    private func milliseconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    // MARK: - measurements

    func testScoringBudgetAt100kAnd275k() {
        for count in [100_000, 275_000] {
            let entries = corpus(count: count)

            // One-time prepare: tokenize every field + parse every date.
            let prepMs = milliseconds {
                _ = LocalSearch.prepare(entries)
            }
            let prepared = LocalSearch.prepare(entries)

            // The per-keystroke budget: scoring against the prepared index.
            let commonMs = milliseconds {
                _ = LocalSearch.results(for: "atproto", prepared: prepared)
            }
            let andMs = milliseconds {
                _ = LocalSearch.results(for: "atproto swift", prepared: prepared)
            }
            let rareMs = milliseconds {
                _ = LocalSearch.results(for: "nonexistentterm", prepared: prepared)
            }

            // What a caller without memoization pays per query.
            let oneShotMs = milliseconds {
                _ = LocalSearch.results(for: "atproto", in: entries)
            }

            print("LocalSearch @ \(count) entries:")
            print(String(format: "  prepare (once)             %8.1f ms", prepMs))
            print(String(format: "  query \"atproto\" (scored)   %8.1f ms", commonMs))
            print(String(format: "  query \"atproto swift\"      %8.1f ms", andMs))
            print(String(format: "  query \"nonexistentterm\"    %8.1f ms", rareMs))
            print(String(format: "  one-shot (prepare+score)   %8.1f ms", oneShotMs))

            // Ceiling scaled to corpus size — far above measured scoring but
            // far below a quadratic regression (matching many hits used to
            // cost ~30 s at 275k via per-comparison date parsing).
            let ceiling = Double(count) / 100_000 * 1_000
            XCTAssertLessThan(commonMs, ceiling)
            XCTAssertLessThan(andMs, ceiling)
            XCTAssertLessThan(rareMs, ceiling)
        }
    }
}
