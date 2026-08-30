import XCTest
import Zat
@testable import ZatAppCore

/// Offline tests for `IdentityResolver`, the seam that lets the offline
/// browse show interaction subjects "as people" (likes/follows/blocks →
/// handles) without blocking the UI or hammering the network: resolution is
/// lazy and cached, failures are cached too, and a throwing/absent resolution
/// yields nil so views fall back to the raw identifier.
final class IdentityResolverTests: XCTestCase {
    private actor Counter {
        var count = 0
        func tick() { count += 1 }
    }

    private actor Capture {
        private var value: (subject: String, name: String, role: IdentityResolver.ResolutionRole)?
        func set(_ subject: String, _ name: String, _ role: IdentityResolver.ResolutionRole) {
            value = (subject, name, role)
        }
        func get() -> (subject: String, name: String, role: IdentityResolver.ResolutionRole)? { value }
    }

    func testResolvesAndCachesSuccess() async {
        let counter = Counter()
        let resolver = IdentityResolver { identifier in
            await counter.tick()
            return identifier == "did:plc:alice" ? "alice.bsky.social" : nil
        }
        let first = await resolver.person(for: "did:plc:alice")
        let second = await resolver.person(for: "did:plc:alice")
        XCTAssertEqual(first, "alice.bsky.social")
        XCTAssertEqual(second, "alice.bsky.social")
        let count = await counter.count
        XCTAssertEqual(count, 1, "repeated requests for the same DID must not re-resolve")
    }

    func testCachesFailuresToo() async {
        let counter = Counter()
        let resolver = IdentityResolver { _ in
            await counter.tick()
            return nil
        }
        let first = await resolver.person(for: "did:plc:unknown")
        let second = await resolver.person(for: "did:plc:unknown")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let count = await counter.count
        XCTAssertEqual(count, 1, "a nil result should be cached as non-resolvable")
    }

    func testThrowingResolutionYieldsNilAndCaches() async {
        enum Boom: Error { case oops }
        let counter = Counter()
        let resolver = IdentityResolver { _ in
            await counter.tick()
            throw Boom.oops
        }
        let first = await resolver.person(for: "did:plc:x")
        let second = await resolver.person(for: "did:plc:x")
        XCTAssertNil(first)
        XCTAssertNil(second)
        let count = await counter.count
        XCTAssertEqual(count, 1, "a throwing resolution should degrade to nil and be cached")
    }

    func testDistinctIdentifiersResolveIndependently() async {
        let counter = Counter()
        let resolver = IdentityResolver { identifier in
            await counter.tick()
            return identifier == "did:plc:one" ? "one.bsky.social" : nil
        }
        let one = await resolver.person(for: "did:plc:one")
        let two = await resolver.person(for: "did:plc:two")
        XCTAssertEqual(one, "one.bsky.social")
        XCTAssertNil(two)
        let count = await counter.count
        XCTAssertEqual(count, 2)
    }

    func testSeededNamesNeverInvokeResolver() async {
        let counter = Counter()
        let resolver = IdentityResolver(
            resolve: { _ in
                await counter.tick()
                return "unexpected.bsky.social"
            },
            initialNames: ["did:plc:alice": "alice.bsky.social"],
            onResolve: { _, _, _ in }
        )
        let name = await resolver.person(for: "did:plc:alice")
        XCTAssertEqual(name, "alice.bsky.social")
        let count = await counter.count
        XCTAssertEqual(count, 0, "seeded entries must short-circuit without resolving")
    }

    func testFreshResolvesAreReportedViaCallback() async {
        let holder = Capture()
        let resolver = IdentityResolver(
            resolve: { id in id == "did:plc:alice" ? "alice.bsky.social" : nil },
            initialNames: [:],
            onResolve: { subject, name, role in
                // hop onto the capture actor (spawned task may lag the callback)
                Task { await holder.set(subject, name, role) }
            }
        )
        _ = await resolver.person(for: "did:plc:alice", role: .person)
        // Give the spawned task a beat to land, then grab the captured value.
        var captured: (subject: String, name: String, role: IdentityResolver.ResolutionRole)?
        for _ in 0..<50 {
            captured = await holder.get()
            if captured != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(captured?.subject, "did:plc:alice")
        XCTAssertEqual(captured?.name, "alice.bsky.social")
        XCTAssertEqual(captured?.role, .person)
    }

    /// A DID referenced as both an account and a feed must be resolved once
    /// and its name shared across roles — the shared cache answers the second
    /// role instantly, and each role's write-through still fires with its own
    /// role so callers persist into the right map.
    func testSharedCacheDedupesAcrossRoles() async {
        let counter = Counter()
        let holder = Capture()
        let resolver = IdentityResolver(
            resolve: { _ in
                await counter.tick()
                return "dual.bsky.social"
            },
            initialNames: [:],
            onResolve: { subject, name, role in
                Task { await holder.set(subject, name, role) }
            }
        )
        // Resolve as a person, then as an entity — same DID.
        let asPerson = await resolver.person(for: "did:plc:dual", role: .person)
        let asEntity = await resolver.person(for: "did:plc:dual", role: .entity)
        XCTAssertEqual(asPerson, "dual.bsky.social")
        XCTAssertEqual(asEntity, "dual.bsky.social")
        let count = await counter.count
        XCTAssertEqual(count, 1, "both roles must share one resolution")

        // The first resolution's write-through carried the person role; the
        // second (cache hit) fires no write-through at all — so the captured
        // one is the person-role write, and no duplicate entity write happens.
        var captured: (subject: String, name: String, role: IdentityResolver.ResolutionRole)?
        for _ in 0..<50 {
            captured = await holder.get()
            if captured != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(captured?.subject, "did:plc:dual")
        XCTAssertEqual(captured?.name, "dual.bsky.social")
        XCTAssertEqual(captured?.role, .person)
    }

    func testResetDropsCacheForRetry() async {
        let counter = Counter()
        let resolver = IdentityResolver { _ in
            await counter.tick()
            return nil
        }
        _ = await resolver.person(for: "did:plc:r")
        resolver.reset()
        _ = await resolver.person(for: "did:plc:r")
        let count = await counter.count
        XCTAssertEqual(count, 2, "reset() should allow a fresh resolution attempt")
    }
}