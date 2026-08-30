import XCTest
import Zat
@testable import ZatAppCore

final class CreatedProbeTests: XCTestCase {
    func testProbeCreatedAt() async throws {
        guard ProcessInfo.processInfo.environment["ZAT_OFFLINE_VERIFY"] == "1" else { throw XCTSkip("opt-in") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cache = RepoCache(directory: base.appendingPathComponent("Atmosplorer/caches", isDirectory: true))
        let target = try XCTUnwrap(try cache.cachedRepos().first { $0.handle == "deborah-10.bsky.social" })
        let session = try AppSession(host: "https://offline.invalid")
        let decoded = try await session.decodeCar(try cache.load(did: target.did))
        let repo = OfflineRepo(did: target.did, recordCar: decoded)
        let posts = repo.records(in: "app.bsky.feed.post")
        for p in posts.prefix(3) {
            print("PROBE createdAt raw = '\(p.value["createdAt"]?.stringValue ?? "NIL")'  type='\(p.value["$type"]?.stringValue ?? "?")'")
        }
    }
}
