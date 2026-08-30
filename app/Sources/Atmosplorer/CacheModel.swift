import Foundation
import Zat
import ZatAppCore

/// One in-flight mirror waiting on the user to confirm a large download.
struct PendingMirror {
    let identity: ZatIdentity
    /// CAR size reported by the probe (bytes).
    let size: Int
}

/// Owns the offline cache: the `RepoCache` on disk, the list of cached repos
/// shown in the sidebar, and the mirror flow (probe the size, optionally warn
/// about very large repos, fetch the CAR on the identity's PDS, then persist
/// it — cancellable at every stage).
///
/// **Progress honesty note:** the core's `getRepo` is one blocking call that
/// returns all bytes at once, so byte-level progress *during* the download
/// isn't available without core streaming support. The mirror instead shows
/// real stage progress ("downloading" → "decoding"), reports the actual byte
/// count the moment the download lands, and persists it so the library list
/// always shows real sizes. Cancellation abandons the wait and discards the
/// result (the in-flight core call drains in the background; nothing is
/// saved).
@MainActor
final class CacheModel: ObservableObject {
    enum MirrorPhase: Equatable {
        case idle
        case probing
        case downloading
        case decoding
    }

    /// Above this, confirm before mirroring — a whole-repo CAR can be very
    /// large (busy accounts like bsky.app are well over this).
    static let largeRepoThresholdBytes = 25 * 1024 * 1024

    @Published var repos: [CachedRepo] = []
    @Published var selectedDid: String?
    @Published var mirrorPhase: MirrorPhase = .idle
    /// Set once the CAR bytes land, so the UI can show a real byte count
    /// while decoding.
    @Published private(set) var downloadedBytes: Int?
    @Published var pendingLargeMirror: PendingMirror?
    @Published var errorMessage: String?

    /// The cache directory backing this model; exposed so views can build
    /// browser models that read from the same store.
    let cache: RepoCache
    /// A session for pure offline work — `decodeCar` never touches the
    /// network, so the host is meaningless. Constructed tolerantly instead of
    /// with `try!`: a failure here must degrade gracefully, never crash the
    /// app at launch.
    let offlineSession: AppSession?

    private var mirrorTask: Task<Void, Never>?

    init(cache: RepoCache? = nil) {
        self.cache = cache ?? RepoCache()
        self.offlineSession = try? AppSession(host: "https://offline.invalid")
        refresh()
    }

    var isDownloading: Bool { mirrorPhase != .idle }

    var isCached: Bool {
        guard let selectedDid else { return false }
        return repos.contains { $0.did == selectedDid }
    }

    func cached(_ did: String) -> Bool {
        repos.contains { $0.did == did }
    }

    /// Pure formatting helper — callable from any context, so it is
    /// explicitly nonisolated rather than MainActor-inherited.
    nonisolated static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - mirror flow

    /// The primary action: probe the CAR size, warn when it's very large, then
    /// fetch the identity's whole CAR from its PDS in one download, persist
    /// it, and jump straight into the fully-offline browse.
    func mirror(identity: ZatIdentity) {
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Sync endpoints (getRepo) live on the PDS, not the appview.
                let dataSession = try AppSession.dataSession(for: identity)
                mirrorPhase = .probing
                let size = await dataSession.probeRepoCarSize(did: identity.did)
                guard !Task.isCancelled else { return }
                if let size, size >= Self.largeRepoThresholdBytes {
                    // Hold for explicit confirmation; the user may decide a
                    // very large download isn't worth it.
                    pendingLargeMirror = PendingMirror(identity: identity, size: size)
                    mirrorPhase = .idle
                    return
                }
                await startMirror(identity: identity, session: dataSession)
            } catch let error as AppError {
                guard !Task.isCancelled else { return }
                mirrorPhase = .idle
                errorMessage = error.userMessage
            } catch {
                guard !Task.isCancelled else { return }
                mirrorPhase = .idle
                errorMessage = "Something unexpected went wrong."
            }
        }
    }

    func confirmLargeMirror() {
        guard let pending = pendingLargeMirror else { return }
        pendingLargeMirror = nil
        mirrorTask?.cancel()
        do {
            let dataSession = try AppSession.dataSession(for: pending.identity)
            mirrorTask = Task { [weak self] in
                await self?.startMirror(identity: pending.identity, session: dataSession)
            }
        } catch let error as AppError {
            mirrorPhase = .idle
            errorMessage = error.userMessage
        } catch {
            mirrorPhase = .idle
            errorMessage = "Something unexpected went wrong."
        }
    }

    func cancelLargeMirror() {
        pendingLargeMirror = nil
        mirrorPhase = .idle
    }

    /// Abandon an in-flight mirror. The download that already started keeps
    /// draining on its session queue (the core call can't be interrupted),
    /// but its result is discarded — nothing is persisted, and the UI is
    /// immediately usable again.
    func cancelMirror() {
        mirrorTask?.cancel()
        mirrorPhase = .idle
        downloadedBytes = nil
    }

    private func startMirror(identity: ZatIdentity, session: AppSession) async {
        mirrorPhase = .downloading
        downloadedBytes = nil
        defer {
            mirrorPhase = .idle
            downloadedBytes = nil
        }
        do {
            let car = try await session.fetchRepoCar(did: identity.did)
            guard !Task.isCancelled else { return }

            downloadedBytes = car.count
            mirrorPhase = .decoding
            guard let decodeSession = offlineSession else {
                throw AppError.unexpected
            }
            let decoded = try await decodeSession.decodeCar(car)
            guard !Task.isCancelled else { return }

            try cache.save(
                did: identity.did, handle: identity.handle,
                car: car, recordCount: decoded.records.count)
            // Build the search index from the same decode pass the mirror
            // already ran. Best-effort: a failed index write only costs a
            // lazy rebuild from the decoded repo on first search, never a
            // failed mirror.
            try? SearchIndex.store(
                did: identity.did, records: decoded.records, in: cache.directory)
            // Drop resolved handles for people/entities this latest mirror no
            // longer references, so re-mirroring doesn't keep showing dropped
            // ones. People (accounts) and entities (starter-pack feeds) are
            // pruned from their own maps.
            var people: Set<String> = []
            var entities: Set<String> = []
            for record in decoded.records {
                let content = RecordContent(value: record.value)
                people.formUnion(content.referencedPersonIdentifiers)
                entities.formUnion(content.referencedEntityIdentifiers)
            }
            try? cache.pruneNames(forRepo: identity.did, referencing: people)
            try? cache.pruneEntities(forRepo: identity.did, referencing: entities)
            refresh()
            selectedDid = identity.did
        } catch let error as AppError {
            guard !Task.isCancelled else { return }
            errorMessage = error.userMessage
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Something unexpected went wrong."
        }
    }

    func remove(_ repo: CachedRepo) {
        try? cache.delete(did: repo.did)
        if selectedDid == repo.did { selectedDid = nil }
        refresh()
    }

    func refresh() {
        repos = (try? cache.cachedRepos()) ?? []
    }
}
