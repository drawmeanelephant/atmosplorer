import XCTest
import Zat
@testable import ZatAppCore
@testable import Atmosplorer

/// UI-level rendering proof for a *real* mirrored repo.
///
/// `OfflineMirrorVerificationTests` proves the CAR decodes offline; this file
/// proves the decoded records actually **render** — each post is pushed
/// through the same `RecordContent` extraction that `RecordContentView` /
/// `RecordRow` consume, and we assert real post text, previews, and kind
/// routing come out the other end.
///
/// Gated behind `ZAT_OFFLINE_VERIFY=1` (depends on the desktop app's local
/// cache). The session host is unroutable, so the whole path is provably
/// offline.
final class OfflineRenderVerificationTests: XCTestCase {
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

    func testMirroredPostTextsRenderThroughRecordContent() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory(), "no Atmosplorer cache directory")
        let cache = RepoCache(directory: cacheDir)
        let target = try XCTUnwrap(
            try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" },
            "deborah-10 mirror not present in cache")

        // Unroutable host: anything that dials the network fails the test.
        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)

        let posts = repo.records(in: "app.bsky.feed.post")
        XCTAssertGreaterThan(posts.count, 100, "mirror should carry a real post corpus")

        // Push every post through the exact extraction the views render.
        var renderedRows = 0
        var texts: [String] = []
        for post in posts {
            let content = RecordContent(value: post.value)
            guard case .post(let parsed) = content.kind else {
                XCTFail("post record \(post.uri) misrouted to \(content.kind)")
                continue
            }
            // A row renders when it has *something* to show: text, an embed
            // card, a quote, or images. RecordRow shows the preview line.
            let rowHasBody = !parsed.text.isEmpty || parsed.external != nil
                || parsed.quote != nil || !parsed.images.isEmpty
            if rowHasBody { renderedRows += 1 }
            if !parsed.text.isEmpty { texts.append(parsed.text) }
            if let created = parsed.createdAt {
                XCTAssertNotNil(RecordContent.dateLabel(created),
                    "createdAt '\(created)' must format for the detail view")
            }
        }

        // The bulk of a real corpus must produce visible rows and real text.
        XCTAssertGreaterThan(renderedRows, posts.count / 2,
            "most post rows must render some body content")
        let nonEmpty = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertGreaterThan(nonEmpty.count, 50, "should extract plenty of real post texts")

        // Spot-check the renderer's input contract on a sample of texts:
        // plain text with control characters stripped out by extraction.
        for text in nonEmpty.prefix(20) {
            XCTAssertFalse(text.contains("\u{0}"), "rendered text must not contain NULs")
        }
    }

    func testMirroredInteractionRecordsRouteToTypedKinds() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory())
        let cache = RepoCache(directory: cacheDir)
        let target = try XCTUnwrap(
            try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" })

        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)

        // Likes/follows/reposts must route to their typed renderers — that's
        // what makes the offline list read as content instead of JSON.
        var kinds: [String: Int] = [:]
        for collection in ["app.bsky.feed.like", "app.bsky.feed.repost", "app.bsky.graph.follow"] {
            for record in repo.records(in: collection) {
                let content = RecordContent(value: record.value)
                let name = "\(content.kind)".split(separator: "(").first.map(String.init) ?? "?"
                kinds[name, default: 0] += 1
            }
        }
        XCTAssertGreaterThan(kinds["like"] ?? 0, 0, "likes must route to the like renderer (detail path)")
        XCTAssertGreaterThan((kinds["follow"] ?? 0) + (kinds["repost"] ?? 0), 0,
            "follows/reposts must route to their typed renderers")
        XCTAssertEqual(kinds["generic"] ?? 0, 0,
            "no interaction record should fall through to the generic dump")
    }

    // MARK: - post detail presentation path

    /// Mirrors what CachedRecordsView does: every record is wrapped in a
    /// RecordSelection and pushed into RecordDetailView, which renders the
    /// typed `.detail` presentation on top and the raw JSON tree below.
    @MainActor
    func testDetailPresentationPathRendersTypedContent() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory())
        let cache = RepoCache(directory: cacheDir)
        let target = try XCTUnwrap(
            try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" })

        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)

        // The window injects a FavoritesModel into the detail view (see
        // RootView); the test supplies one backed by a throwaway directory so
        // the real cache is never touched.
        let favoritesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atmosplorer-render-tests-\(UUID().uuidString)", isDirectory: true)
        let favorites = FavoritesModel(store: FavoritesStore(directory: favoritesDir))
        defer { try? FileManager.default.removeItem(at: favoritesDir) }

        var checked = 0
        var detailTexts = 0
        for collection in ["app.bsky.feed.post", "app.bsky.feed.like",
                           "app.bsky.feed.repost", "app.bsky.graph.follow"] {
            for record in repo.records(in: collection) {
                // Exactly what CachedRecordsView does per row.
                let selection = RecordSelection(
                    uri: record.uri, cid: record.cid, value: record.value)

                // The detail view's typed renderer input.
                let content = RecordContent(value: selection.value)
                XCTAssertNotEqual(content.kind, .generic,
                    "detail of \(selection.uri) fell through to the generic dump")

                // Force-build the detail view body with the same environment
                // the window provides. `body` is a computed @ViewBuilder
                // property; evaluating it proves the section inputs (typed
                // content + JSON tree + favorites star) resolve.
                let view = RecordDetailView(selection: selection)
                    .environmentObject(favorites)
                _ = view.body

                // The JSON tree below the typed section must force-build too:
                // every node in the record body must produce leaf text without
                // crashing (this is the tree JSONTreeView walks).
                XCTAssertFalse(JSONTreeView.forceBuildAllLeafTexts(selection.value).isEmpty,
                    "JSON tree must render for \(selection.uri)")

                checked += 1
                if case .post(let parsed) = content.kind, !parsed.text.isEmpty {
                    detailTexts += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "detail path must cover a real corpus")
        XCTAssertGreaterThan(detailTexts, 50, "detail path must render real post texts")
    }

    /// Force-build every node the detail view's JSONTreeView walks: every
    /// node in the record body must produce leaf text without crashing.
    func testJSONTreeForceBuildsAllLeafTexts() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory())
        let cache = RepoCache(directory: cacheDir)
        let target = try XCTUnwrap(
            try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" })

        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)

        var leafCount = 0
        for record in repo.records(in: "app.bsky.feed.post") {
            let value = record.value
            let leaves = await MainActor.run {
                JSONTreeView.forceBuildAllLeafTexts(value)
            }
            leafCount += leaves.count
        }
        XCTAssertGreaterThan(leafCount, 1000,
            "JSON tree of the real corpus must force-build every leaf")
    }
}
