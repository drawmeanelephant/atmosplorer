import Foundation

/// Resolves AT Protocol identifiers (handles or DIDs) to a human-readable
/// name for display — e.g. turning a like/follow/block's bare subject DID
/// into `alice.bsky.social`.
///
/// This is the seam that lets the "offline-first" browse still show real
/// people without blocking the UI: resolution is **lazy and cached**, and the
/// caller always has the raw identifier as a fallback to show until/unless a
/// name comes back. `person(for:)` caches both successes (a handle) and
/// failures (a known-unresolvable identifier), so a given DID is resolved at
/// most once per session regardless of how many records reference it.
///
/// Thread-safe (NSLock). The resolving closure itself is injected, so tests
/// can script it and the app can back it with an `AppSession` (which does the
/// blocking C call on its own serial queue).
public final class IdentityResolver: @unchecked Sendable {
    public typealias Resolve = @Sendable (String) async throws -> String?

    /// What role an identifier plays in the browse — an **account** (a
    /// like/follow/block/repost subject, persisted in the people map) or an
    /// **entity** (a starter-pack feed generator, persisted in the entities
    /// map). One resolver serves both so the same DID is ever resolved once,
    /// with the write-through routing by role.
    public enum ResolutionRole: Sendable {
        case person
        case entity
    }

    private let lock = NSLock()
    private var resolved: [String: String] = [:]   // did/handle → display name
    private var unresolved: Set<String> = []        // identifiers known to have none
    private let resolve: Resolve
    /// Persistence hook: called (off-lock) with (identifier, name, role) for
    /// each freshly resolved handle so callers can persist it for later
    /// offline use — routing into the people or entities map by role.
    private var onResolve: (@Sendable (String, String, ResolutionRole) -> Void)?

    public init(resolve: @escaping Resolve) {
        self.resolve = resolve
        self.resolved = [:]
        self.onResolve = nil
    }

    /// Seed from a persisted map (so a repo browsed online shows the same
    /// people immediately, offline) and report each new resolution via
    /// `onResolve` so it can be written back to disk. Seeded entries never
    /// invoke the resolver or the callback. Names seeded from either role are
    /// shared: a DID known from the entities map also answers a `person`
    /// lookup without re-resolving.
    public convenience init(
        resolve: @escaping Resolve,
        initialNames: [String: String],
        onResolve: (@Sendable (String, String, ResolutionRole) -> Void)?
    ) {
        self.init(resolve: resolve)
        self.resolved = initialNames
        self.onResolve = onResolve
    }

    /// Convenience backed by `AppSession.resolveIdentity` (returns the
    /// primary handle, i.e. the human name).
    public convenience init(
        session: AppSession,
        initialNames: [String: String] = [:],
        onResolve: (@Sendable (String, String, ResolutionRole) -> Void)? = nil
    ) {
        self.init(
            resolve: { identifier in
                try? await session.resolveIdentity(identifier).handle
            },
            initialNames: initialNames,
            onResolve: onResolve)
    }

    /// The display name for `identifier`, resolving on first use and caching
    /// the result. `nil` means either `identifier` is a bare form with no
    /// known name (e.g. an at:// URI authority) or resolution failed — the
    /// caller should keep showing the raw identifier. `role` only affects the
    /// write-through (which persisted map the name lands in); the cache is
    /// shared, so a DID resolved once under either role answers instantly
    /// under the other.
    public func person(for identifier: String, role: ResolutionRole = .person) async -> String? {
        // `NSLock` must not be touched from an async context directly, so the
        // cache reads/writes happen inside synchronous helpers below.
        if let cached = readCache(identifier) {
            return cached   // `nil` here opts into re-resolution; see readCache
        }
        let result = try? await resolve(identifier)
        if let (subject, name) = writeCache(identifier, result) {
            onResolve?(subject, name, role)
        }
        return result
    }

    /// Drop cached names (e.g. on session teardown); keeps the class usable.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        resolved.removeAll()
        unresolved.removeAll()
    }

    // Synchronous cache access; returns `nil` when `identifier` hasn't been
    // tried yet and `.some(value)` (handle or a cached failure) otherwise.
    private func readCache(_ identifier: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        if let name = resolved[identifier] { return .some(name) }
        if unresolved.contains(identifier) { return .some(nil) }
        return nil
    }

    private func writeCache(_ identifier: String, _ name: String?) -> (String, String)? {
        lock.lock()
        defer { lock.unlock() }
        if let name {
            resolved[identifier] = name
            return (identifier, name)
        }
        unresolved.insert(identifier)
        return nil
    }
}

/// Derives the *person* an interaction points at, so the views can resolve
/// "as people": a like/repost's subject is a record URI whose **author** is
/// the person; a follow/block's subject is the actor itself.
public enum SubjectIdentity {
    /// The identifier (DID or handle) naming the person for an interaction.
    /// Prefers the author of a referenced record URI, then a direct subject
    /// DID.
    public static func personIdentifier(uri: String?, did: String?) -> String? {
        if let uri, let authority = authority(ofATURI: uri) { return authority }
        return did
    }

    /// The authority segment of an at:// URI (the DID or handle before the
    /// first `/`), e.g. `at://did:plc:abc/app.bsky.feed.post/rkey` →
    /// `did:plc:abc`. Nil when not an at:// URI.
    public static func authority(ofATURI uri: String) -> String? {
        guard uri.hasPrefix("at://") else { return nil }
        let rest = uri.dropFirst("at://".count)
        if let slash = rest.firstIndex(of: "/") {
            return String(rest[..<slash])
        }
        return rest.isEmpty ? nil : String(rest)
    }
}