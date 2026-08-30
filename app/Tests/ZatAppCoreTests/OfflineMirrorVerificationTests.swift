import XCTest
import Zat
@testable import ZatAppCore

/// Verification that a *real* mirrored repo browses fully offline.
///
/// Gated behind `ZAT_OFFLINE_VERIFY=1` because it depends on the local
/// Atmosplorer cache produced by the desktop app (a mirrored repo). The
/// AppSession under test is constructed against an intentionally unroutable
/// host (`https://offline.invalid`), so any network touch fails loudly —
/// everything here must come from the CAR bytes on disk.
final class OfflineMirrorVerificationTests: XCTestCase {
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

    func testMirroredRepoDecodesFullyOffline() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else {
            throw XCTSkip("opt-in: set ZAT_OFFLINE_VERIFY=1 with a populated app cache")
        }
        let cacheDir = try XCTUnwrap(realCacheDirectory(), "no Atmosplorer cache directory")
        let cache = RepoCache(directory: cacheDir)
        let repos = try cache.cachedRepos()
        let target = try XCTUnwrap(
            repos.first { $0.handle == "deborah-10.bsky.social" },
            "deborah-10 mirror not present in cache")

        // Zero-network session: any HTTP attempt resolves offline.invalid and fails.
        let session = try AppSession(host: "https://offline.invalid")

        // 1. Load the raw CAR from disk (RepoCache, no network).
        let car = try cache.load(did: target.did)
        XCTAssertEqual(car.count, target.carByteCount ?? -1)

        // 2. Decode through the Zig core — pure CPU, no I/O.
        let decoded = try await session.decodeCar(car)
        XCTAssertGreaterThan(decoded.records.count, 0)
        XCTAssertEqual(decoded.records.count, target.recordCount,
            "decoded record count should match the count recorded at mirror time")

        // 3. Shape into the offline browse model and confirm content renders.
        let repo = OfflineRepo(did: target.did, recordCar: decoded)
        XCTAssertFalse(repo.collections.isEmpty, "offline browse must show collections")
        for collection in repo.collections {
            XCTAssertFalse(repo.records(in: collection).isEmpty,
                "collection \(collection) must render at least one record")
            for record in repo.records(in: collection) {
                XCTAssertTrue(record.uri.hasPrefix("at://\(target.did)/"),
                    "synthesized URI must be well-formed: \(record.uri)")
                XCTAssertNotNil(record.cid)
                if case .null = record.value {
                    XCTFail("record \(record.uri) must have decoded content, got null")
                }
            }
        }
        // The mirrored repo's own posts must be present (its author is a party
        // to every app.bsky.feed.post record).
        let posts = repo.records(in: "app.bsky.feed.post")
        XCTAssertFalse(posts.isEmpty, "mirrored repo must render its own posts")
    }
}
