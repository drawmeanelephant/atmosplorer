import Foundation
import ZatAppCore

/// Drives the offline browse of one cached repo: load the CAR from disk,
/// decode it (zero network), and shape it into collections + records.
@MainActor
final class CachedRepoBrowserModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published var phase: Phase = .loading
    @Published var offline: OfflineRepo?
    @Published var selectedCollection: String?

    let did: String
    let displayName: String

    /// The backing store; read by `SearchModel` to load the repo's index.
    let cache: RepoCache
    private let session: AppSession

    /// Resolves interaction subjects (DIDs / handles) to human names so the
    /// offline browse shows likes/follows/blocks as people (and starter-pack
    /// feeds as entities). **One shared resolver** serves both roles: it's
    /// seeded from the people *and* entities persisted maps (so a repo browsed
    /// online shows the same names offline later), and a DID referenced as
    /// both an account and a feed is resolved exactly once — the write-through
    /// routes each fresh resolution into its role's file (`.names.json` for
    /// people, `.entities.json` for feeds), so the maps stay role-clean while
    /// the in-session cache is shared.
    let resolver: IdentityResolver

    init(did: String, displayName: String, cache: RepoCache, session: AppSession) {
        self.did = did
        self.displayName = displayName
        self.cache = cache
        self.session = session
        // Seed from both maps; on a conflict (same DID named differently as
        // an account vs a feed) the people-map name wins.
        let seeded = cache.loadNames(forRepo: did)
            .merging(cache.loadEntities(forRepo: did)) { current, _ in current }
        let storage: RepoCache = cache
        self.resolver = IdentityResolver(
            session: session,
            initialNames: seeded,
            onResolve: { identifier, name, role in
                DispatchQueue.global(qos: .utility).async {
                    switch role {
                    case .person:
                        try? storage.storeName(name, forSubject: identifier, inRepo: did)
                    case .entity:
                        try? storage.storeEntity(name, forSubject: identifier, inRepo: did)
                    }
                }
            })
    }

    var recordCount: Int { offline?.recordCount ?? 0 }

    func load() async {
        do {
            let data = try cache.load(did: did)
            let car = try await session.decodeCar(data)
            let repo = OfflineRepo(did: did, recordCar: car)
            offline = repo
            selectedCollection = repo.collections.first
            phase = .loaded
        } catch let error as AppError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something unexpected went wrong.")
        }
    }
}
