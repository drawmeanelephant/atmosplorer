import XCTest
import Zat
@testable import ZatAppCore

/// A "corpus census" — mines the real mirrored deborah-10 repo for fun
/// activity stats, entirely offline (unroutable session host).
///
/// Opt-in via ZAT_OFFLINE_VERIFY=1 (depends on the desktop app's local cache).
final class CorpusCensusTests: XCTestCase {
    private func realCacheDirectory() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Atmosplorer", isDirectory: true)
            .appendingPathComponent("caches", isDirectory: true)
        var isDir: ObjCBool = false
        guard let dir, FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return dir
    }

    private struct DayKey: Hashable { let year: Int; let month: Int; let day: Int }

    func testCorpusCensus() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory(), "no Atmosplorer cache directory")
        let cache = RepoCache(directory: cacheDir)
        let target = try XCTUnwrap(
            try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" },
            "deborah-10 mirror not present in cache")

        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)

        let posts = repo.records(in: "app.bsky.feed.post")
        let likes = repo.records(in: "app.bsky.feed.like").count
        let reposts = repo.records(in: "app.bsky.feed.repost").count
        let follows = repo.records(in: "app.bsky.graph.follow").count

        // --- parse createdAt into calendar days -------------------------------
        let iso = ISO8601DateFormatter()
        let cal = Calendar(identifier: .gregorian)
        var perDay: [DayKey: Int] = [:]
        var perHour = Array(repeating: 0, count: 24)
        var earliest: (Date, String)?
        var latest: (Date, String)?

        // --- text mining ------------------------------------------------------
        var longest: (text: String, uri: String, len: Int)?
        var emojiFreq: [Character: Int] = [:]
        var selfQuotes = 0
        var totalChars = 0
        var withEmbeds = 0

        let emojiRanges: [ClosedRange<UInt32>] = [
            0x1F300...0x1FAFF, 0x2600...0x27BF, 0x2190...0x21FF, 0x2B00...0x2BFF,
        ]
        func isEmoji(_ c: Character) -> Bool {
            for scalar in c.unicodeScalars {
                if emojiRanges.contains(where: { $0.contains(scalar.value) }) { return true }
            }
            return false
        }

        for post in posts {
            let content = RecordContent(value: post.value)
            guard case .post(let parsed) = content.kind else { continue }

            let text = parsed.text
            totalChars += text.count
            if parsed.external != nil || parsed.quote != nil || !parsed.images.isEmpty {
                withEmbeds += 1
            }
            if let quote = parsed.quote, quote.contains(target.did) { selfQuotes += 1 }

            if text.count > (longest?.len ?? 0) {
                longest = (text, post.uri, text.count)
            }
            for c in text where isEmoji(c) { emojiFreq[c, default: 0] += 1 }

            if let created = parsed.createdAt, let date = iso.date(from: created) {
                let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
                if let y = comps.year, let m = comps.month, let d = comps.day, let h = comps.hour {
                    perDay[DayKey(year: y, month: m, day: d), default: 0] += 1
                    perHour[h] += 1
                    if earliest == nil || date < earliest!.0 { earliest = (date, created) }
                    if latest == nil || date > latest!.0 { latest = (date, created) }
                }
            }
        }

        // --- derive fun stats ---------------------------------------------------
        let dayCount = perDay.count
        let total = posts.count
        let busiest = perDay.max { $0.value < $1.value }
        let activeDays = perDay.filter { $0.value >= 5 }.count
        let fmt = Date.FormatStyle.dateTime.year().month(.abbreviated).day()

        print("\n══════════════ CORPUS CENSUS: \(target.displayName) ══════════════")
        print("posts: \(total)  likes: \(likes)  reposts: \(reposts)  follows: \(follows)")
        print("avg chars/post: \(total > 0 ? totalChars / total : 0)  posts with embeds: \(withEmbeds) (\(total > 0 ? withEmbeds * 100 / total : 0)%)")
        print("self-quotes (threads): \(selfQuotes)")
        if let longest {
            print("longest post: \(longest.len) chars — \(longest.text.prefix(220))…")
        }
        let topEmoji = emojiFreq.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
        print("top emoji: \(topEmoji.isEmpty ? "none" : topEmoji)")
        if let earliest, let latest {
            print("first post: \(earliest.0.formatted(fmt))   latest: \(latest.0.formatted(fmt))")
        }
        print("active days: \(dayCount)  (≥5 posts/day: \(activeDays))")
        if dayCount > 0, let earliest, let latest {
            let spanDays = max(1, Int(latest.0.timeIntervalSince(earliest.0) / 86400))
            print("cadence: \(String(format: "%.1f", Double(total) / Double(spanDays))) posts/day over \(spanDays)d span; \(String(format: "%.1f", Double(total) / Double(dayCount))) posts per active day")
        }
        if let busiest, let b = cal.date(from: DateComponents(year: busiest.key.year, month: busiest.key.month, day: busiest.key.day)) {
            print("busiest day: \(b.formatted(fmt)) with \(busiest.value) posts")
        }
        let hourMax = perHour.enumerated().max { $0.element < $1.element }
        if let hourMax { print("peak hour (UTC-ish, as stored): \(hourMax.offset):00 with \(hourMax.element) posts") }
        print("══════════════════════════════════════════════════════════════\n")

        // --- sanity assertions (still a test) ---------------------------------
        XCTAssertGreaterThan(total, 100)
        XCTAssertGreaterThan(likes + reposts + follows, 0, "interaction records expected")
        if let longest { XCTAssertGreaterThan(longest.len, 0) }
    }
}
