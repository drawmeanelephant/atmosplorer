import XCTest
import Zat
@testable import ZatAppCore

/// Live tests for the app's *own* async traversal stack against real ATProto
/// infrastructure. This is exactly the path the UI drives: `RootModel.explore`
/// (AppSession → resolveIdentity → describeRepo) and then `RecordsModel`
/// (listRecords, page-by-page through the cursor), plus the AppError mapping
/// that seam applies.
///
/// The traversal is exercised across three repo sizes so paging and exhaustion
/// behavior is hardened against accounts that behave differently (a single
/// page of records vs. many). The unbounded walk-to-exhaustion is deliberately
/// reserved for the small fixture so we don't hammer the public API against a
/// huge repo; larger repos get a bounded multi-page walk instead.
///
/// Gated behind `ZAT_INTEGRATION=1` so the default `swift test` stays fully
/// offline (ZatFakeTransport + embedded CAR fixture), mirroring the wrapper's
/// ZatExplorerIntegrationTests:
///
///     ZAT_INTEGRATION=1 swift test --filter AppLiveTraversalIntegrationTests
final class AppLiveTraversalIntegrationTests: XCTestCase {
    private enum RepoSize: String {
        case small
        case medium
        case large
    }

    private struct Fixture {
        let handle: String
        let size: RepoSize
    }

    /// Handles chosen to span repo sizes. Order matters only for the
    /// small-repo exhaustion test, which keys off `RepoSize.small`.
    private let liveRepos: [Fixture] = [
        .init(handle: "atproto.com", size: .small),
        .init(handle: "jay.bsky.team", size: .medium),
        .init(handle: "bsky.app", size: .large),
    ]

    private func requireIntegration() throws {
        guard ProcessInfo.processInfo.environment["ZAT_INTEGRATION"] == "1" else {
            throw XCTSkip("set ZAT_INTEGRATION=1 to run live tests against real ATProto infrastructure")
        }
    }

    /// Same bootstrap AppSession the app's RootModel constructs for public
    /// reads: one async seam, bound to the public appview. Reused across all
    /// fixtures in a test, mirroring how a single window explores many handles.
    private func bootstrapSession() throws -> AppSession {
        try requireIntegration()
        return try AppSession(host: "https://bsky.social")
    }

    // MARK: - identity resolution

    func testResolveIdentityAcrossRepoSizes() async throws {
        let session = try bootstrapSession()
        for fixture in liveRepos {
            let identity = try await session.resolveIdentity(fixture.handle)

            XCTAssertTrue(identity.did.hasPrefix("did:plc:"), "\(fixture.handle)")
            XCTAssertEqual(identity.handle, fixture.handle, "\(fixture.handle)")
            XCTAssertNotNil(identity.pds, "\(fixture.handle)")
        }
    }

    // MARK: - describeRepo

    func testDescribeRepoAcrossRepoSizes() async throws {
        let session = try bootstrapSession()
        for fixture in liveRepos {
            let identity = try await session.resolveIdentity(fixture.handle)
            let description = try await session.describeRepo(identity.did)

            XCTAssertEqual(description.did, identity.did, "\(fixture.handle)")
            XCTAssertTrue(
                description.collections.contains("app.bsky.feed.post"),
                "\(fixture.handle) should publish posts, got \(description.collections)")
        }
    }

    // MARK: - cross-role dedupe (feed generator that is also followed)

    /// The dual-role condition that cross-role dedupe exists for: a repo that
    /// follows a feed-generator account *and* embeds that feed in one of its
    /// starter packs, so the generator's DID lands in both the people set
    /// (follow subject) and the entity set (pack feed).
    ///
    /// The fixture list lives in `Fixtures/dual-role-fixtures.json` (handle +
    /// the expected dual DID) so maintainers can add or retire fixtures — or
    /// refresh them when a repo's follows/packs drift — by editing JSON only,
    /// never test code. The test needs *at least one* fixture to hold its
    /// expected dual condition, and asserts on the first one that does; a
    /// stale fixture is skipped and its reason reported, so a single repo
    /// regressing doesn't silently starve the assertion.
    func testDualRoleDidResolvesOnceAcrossRoles() async throws {
        // Gate first so offline runs skip before touching the bundle.
        let session = try bootstrapSession()
        let fixtures = try Self.loadDualRoleFixtures()
        var asserted = false
        var reasons: [String] = []

        for fixture in fixtures {
            let handle = fixture.handle
            do {
                let identity = try await session.resolveIdentity(handle)

                // Mirror exactly as CacheModel does: PDS CAR → decode (no appview).
                let dataSession = try AppSession.dataSession(for: identity)
                let car = try await dataSession.fetchRepoCar(did: identity.did)
                let decoded = try await session.decodeCar(car)
                let repo = OfflineRepo(did: identity.did, recordCar: decoded)

                // Derive the person and entity sets from the *mirrored*
                // records — the same rule the mirror's prune step uses.
                var people: Set<String> = []
                var entities: Set<String> = []
                for record in repo.records {
                    let content = RecordContent(value: record.value)
                    people.formUnion(content.referencedPersonIdentifiers)
                    entities.formUnion(content.referencedEntityIdentifiers)
                }

                // The condition this test exists for: the fixture's expected
                // DID is both a followed account and a starter-pack feed.
                let dual = people.intersection(entities)
                guard dual.contains(fixture.dualDID) else {
                    reasons.append("\(handle): expected dual DID \(fixture.dualDID) is not both followed and packed (people ∩ entities = \(dual))")
                    continue
                }

                // Prove one resolution across both roles: count how many
                // times the underlying resolver closure actually runs.
                let counter = ResolutionCounter()
                let resolver = IdentityResolver(
                    resolve: { identifier in
                        await counter.tick()
                        return try? await session.resolveIdentity(identifier).handle
                    },
                    initialNames: [:],
                    onResolve: { _, _, _ in }
                )
                let asPerson = await resolver.person(for: fixture.dualDID, role: .person)
                let asEntity = await resolver.person(for: fixture.dualDID, role: .entity)

                XCTAssertNotNil(asPerson, "the dual-role feed generator should resolve live (\(handle))")
                XCTAssertEqual(asPerson, asEntity, "both roles must share the same resolved name (\(handle))")
                let count = await counter.count
                XCTAssertEqual(count, 1, "a DID referenced as both account and feed must resolve exactly once (\(handle))")

                // Persistence: exercise CacheModel's prune step against a real
                // on-disk RepoCache. Seed still-referenced people/entities plus
                // the resolved dual handle into both maps, add stale entries
                // the mirror no longer references, prune with the exact sets
                // CacheModel uses, reload, and assert the round-trip.
                let cacheDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("atmosplorer-dual-live-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: cacheDir) }
                let cache = RepoCache(directory: cacheDir)
                let repoDID = identity.did

                // Seed real identifiers the mirror still references.
                let seedPeople = people.filter { $0 != fixture.dualDID }.prefix(3)
                let seedEntities = entities.filter { $0 != fixture.dualDID }.prefix(3)
                for (i, subject) in seedPeople.enumerated() {
                    try cache.storeName("p-\(i)", forSubject: subject, inRepo: repoDID)
                }
                for (i, subject) in seedEntities.enumerated() {
                    try cache.storeEntity("e-\(i)", forSubject: subject, inRepo: repoDID)
                }
                // The dual DID is both followed AND a feed, so its resolved
                // handle belongs in both maps.
                if let dualHandle = asPerson {
                    try cache.storeName(dualHandle, forSubject: fixture.dualDID, inRepo: repoDID)
                    try cache.storeEntity(dualHandle, forSubject: fixture.dualDID, inRepo: repoDID)
                }
                // Stale entries the latest mirror no longer references.
                try cache.storeName("stale-person", forSubject: "did:plc:stale-live-person", inRepo: repoDID)
                try cache.storeEntity("stale-feed", forSubject: "did:plc:stale-live-feed", inRepo: repoDID)

                // The mirror's prune step, verbatim from CacheModel.
                try cache.pruneNames(forRepo: repoDID, referencing: people)
                try cache.pruneEntities(forRepo: repoDID, referencing: entities)

                // Reload from disk and verify keepers survived, stale dropped.
                let names = cache.loadNames(forRepo: repoDID)
                let entitiesMap = cache.loadEntities(forRepo: repoDID)
                XCTAssertNil(names["did:plc:stale-live-person"], "\(handle): stale person must be pruned")
                XCTAssertNil(entitiesMap["did:plc:stale-live-feed"], "\(handle): stale feed must be pruned")
                if let dualHandle = asPerson {
                    XCTAssertEqual(names[fixture.dualDID], dualHandle, "\(handle): resolved dual handle round-trips to the people map")
                    XCTAssertEqual(entitiesMap[fixture.dualDID], dualHandle, "\(handle): resolved dual handle round-trips to the entity map")
                }
                for (i, subject) in seedPeople.enumerated() {
                    XCTAssertEqual(names[subject], "p-\(i)", "\(handle): referenced person should survive pruning")
                }
                for (i, subject) in seedEntities.enumerated() {
                    XCTAssertEqual(entitiesMap[subject], "e-\(i)", "\(handle): referenced entity should survive pruning")
                }

                asserted = true
                break
            } catch {
                reasons.append("\(handle): \(error)")
            }
        }

        XCTAssertTrue(asserted, "no dual-role fixture held the feed-generator-also-followed condition: \(reasons.joined(separator: "; "))")
    }

    /// One entry of `Fixtures/dual-role-fixtures.json`.
    private struct DualRoleFixture: Decodable {
        let handle: String
        let dualDID: String
    }

    /// Loads the fixture list from the test bundle. Fails loudly when the
    /// JSON is missing or malformed so a fixture typo is never silent.
    private static func loadDualRoleFixtures() throws -> [DualRoleFixture] {
        guard let url = Bundle.module.url(
            forResource: "dual-role-fixtures", withExtension: "json", subdirectory: "Fixtures"
        ) else {
            struct MissingFixture: Error, CustomStringConvertible {
                var description: String { "Fixtures/dual-role-fixtures.json missing from the test bundle" }
            }
            throw MissingFixture()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([DualRoleFixture].self, from: data)
    }

    /// Offline guard for the externalized fixture file: schema, non-empty
    /// lowercase handles, well-formed DIDs, no duplicate handles. Runs in the
    /// default (offline) suite so a fixture typo fails fast — before any live
    /// run pays the network cost.
    func testDualRoleFixturesFileIsWellFormed() throws {
        let fixtures = try Self.loadDualRoleFixtures()
        XCTAssertFalse(fixtures.isEmpty, "dual-role-fixtures.json must list at least one repo")
        var seen: Set<String> = []
        for fixture in fixtures {
            XCTAssertFalse(fixture.handle.isEmpty, "fixture handle must not be empty")
            XCTAssertEqual(
                fixture.handle, fixture.handle.lowercased(),
                "fixture handle must be lowercase: \(fixture.handle)")
            XCTAssertTrue(
                Self.isValidHandle(fixture.handle),
                "fixture handle is not a valid AT handle: \(fixture.handle)")
            XCTAssertTrue(
                Self.isValidDID(fixture.dualDID),
                "fixture dualDID is not a well-formed DID: \(fixture.dualDID)")
            XCTAssertTrue(
                seen.insert(fixture.handle).inserted,
                "duplicate fixture handle: \(fixture.handle)")
        }
    }

    /// The validators must not be vacuously true: good values pass, and the
    /// typos this test exists to catch actually fail.
    func testFixtureValidatorsRejectTypos() {
        XCTAssertTrue(Self.isValidHandle("thegreatcomictree.bsky.social"))
        XCTAssertTrue(Self.isValidHandle("dynamic2034.bsky.social"))
        XCTAssertFalse(Self.isValidHandle("NoDotsHere"))
        XCTAssertFalse(Self.isValidHandle("has.Uppercase.bsky.social"))
        XCTAssertFalse(Self.isValidHandle("-leading-hyphen.bsky.social"))
        XCTAssertFalse(Self.isValidHandle("trailing-hyphen-.bsky.social"))
        XCTAssertFalse(Self.isValidHandle("double..dot.bsky.social"))
        XCTAssertFalse(Self.isValidHandle(""))

        XCTAssertTrue(Self.isValidDID("did:plc:z72i7hdynmk6r22z27h6tvur"))
        XCTAssertTrue(Self.isValidDID("did:web:example.com:user"))
        XCTAssertFalse(Self.isValidDID("did:plc:"))
        XCTAssertFalse(Self.isValidDID("plc:z72i7hdynmk6r22z27h6tvur"))
        XCTAssertFalse(Self.isValidDID("did:plc:has whitespace"))
        XCTAssertFalse(Self.isValidDID("DID:plc:z72i7hdynmk6r22z27h6tvur"))
    }

    /// AT handles are lowercase, dot-separated labels of ASCII letters,
    /// digits, and hyphens — at least two labels, none starting/ending with
    /// a hyphen, each ≤ 63 chars, total ≤ 253.
    private static func isValidHandle(_ handle: String) -> Bool {
        guard !handle.isEmpty, handle.count <= 253,
              handle.allSatisfy({ $0.isASCII && !$0.isUppercase && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") })
        else { return false }
        let labels = handle.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else { return false }
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last else { return false }
            return (first.isLetter || first.isNumber) && (last.isLetter || last.isNumber)
        }
    }

    /// `did:<method>:<id>` — lowercase ASCII method, non-empty id, no
    /// whitespace anywhere.
    private static func isValidDID(_ did: String) -> Bool {
        let parts = did.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "did" else { return false }
        let method = parts[1]
        guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return false }
        let id = parts.dropFirst(2).joined(separator: ":")
        return !id.isEmpty && id.allSatisfy { $0.isASCII && !$0.isWhitespace }
    }

    // MARK: - listRecords

    func testListRecordsFirstPageAcrossRepoSizes() async throws {
        let session = try bootstrapSession()
        for fixture in liveRepos {
            let identity = try await session.resolveIdentity(fixture.handle)

            // listRecords as the app's RecordsModel calls it: JSONValue model,
            // 25 per page.
            let page = try await session.listRecords(
                repo: identity.did, collection: "app.bsky.feed.post", limit: 25)

            XCTAssertFalse(page.records.isEmpty, "\(fixture.handle)")
            for record in page.records {
                XCTAssertTrue(
                    record.uri.hasPrefix("at://\(identity.did)/app.bsky.feed.post/"),
                    "\(fixture.handle)")
                XCTAssertEqual(
                    record.value["$type"]?.stringValue, "app.bsky.feed.post",
                    "\(fixture.handle)")
            }
        }
    }

    /// Bounded multi-page walk, run on every size, so larger repos still
    /// exercise real paging (distinct consecutive pages) without requiring an
    /// unbounded walk. Degenerate one-page repos just don't get the
    /// two-distinct-pages assertion.
    func testPagingAcrossRepoSizes() async throws {
        let session = try bootstrapSession()
        for fixture in liveRepos {
            let identity = try await session.resolveIdentity(fixture.handle)

            var pages: [[ZatRecord<ZatJSONValue>]] = []
            var cursor: String?
            repeat {
                let page = try await session.listRecords(
                    repo: identity.did, collection: "app.bsky.feed.post",
                    limit: 25, cursor: cursor)
                pages.append(page.records)
                cursor = page.cursor
            } while cursor != nil && pages.count < 3

            XCTAssertFalse(pages.isEmpty, "\(fixture.handle)")
            XCTAssertTrue(
                pages.allSatisfy { !$0.isEmpty },
                "\(fixture.handle): every fetched page should be non-empty")
            for page in pages {
                XCTAssertTrue(
                    page.allSatisfy { $0.uri.hasPrefix("at://\(identity.did)/app.bsky.feed.post/") },
                    "\(fixture.handle)")
            }

            if pages.count >= 2 {
                XCTAssertNotEqual(
                    pages[0].first?.uri, pages[1].first?.uri,
                    "\(fixture.handle): consecutive pages should return different records")
            }
        }
    }

    /// The unbounded exhaustion walk (RecordsModel keeps loading until the
    /// server returns no cursor) is only safe to run against a small repo —
    /// a huge one would need hundreds of paginated requests. Reserved for the
    /// small fixture; larger repos are covered by the bounded walk above.
    func testListRecordsWalksToExhaustionOnSmallRepo() async throws {
        guard let small = liveRepos.first(where: { $0.size == .small }) else {
            throw XCTSkip("no small-repo fixture configured")
        }
        let session = try bootstrapSession()
        let identity = try await session.resolveIdentity(small.handle)

        var records: [ZatRecord<ZatJSONValue>] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await session.listRecords(
                repo: identity.did, collection: "app.bsky.feed.post",
                limit: 25, cursor: cursor)
            records.append(contentsOf: page.records)
            cursor = page.cursor
            pages += 1
            // Guard against a pathological repo that never runs dry.
            if pages > 50 { break }
        } while cursor != nil

        XCTAssertGreaterThan(pages, 0)
        XCTAssertFalse(records.isEmpty)
        XCTAssertLessThanOrEqual(records.count, pages * 25)
        XCTAssertTrue(
            records.allSatisfy { $0.uri.hasPrefix("at://\(identity.did)/app.bsky.feed.post/") })

        // A fully-walked listing is exhausted: last page had no cursor. (The
        // loop only breaks early on the pathological guard, so reaching here
        // with a non-empty list and cursor == nil means exhaustion.)
        XCTAssertNil(cursor, "listRecords should eventually stop returning a cursor")
    }
}

/// Counts how many times a resolution closure actually ran (thread-safe).
private actor ResolutionCounter {
    private var value = 0
    func tick() { value += 1 }
    var count: Int { value }
}