import Zat
import SwiftUI
import ZatAppCore

/// One column: handle entry + resolved identity with the primary **Mirror
/// repo** action (materialize a full offline copy in a single atomic
/// download), a demoted live browse behind an opt-in toggle, and the offline
/// cache library. Selecting a cached repo drives the fully-offline browse.
@MainActor
struct SidebarView: View {
    @ObservedObject var model: RootModel
    @ObservedObject var cacheModel: CacheModel
    @ObservedObject var favoritesModel: FavoritesModel
    @Binding var handleInput: String
    @Binding var showLivePreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            entryField
            if let identity = model.identity {
                identitySummary(identity)
                if cacheModel.cached(identity.did) {
                    Text("Browsing the mirrored offline copy — no live network needed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    livePreviewToggle
                    if showLivePreview {
                        collectionList
                    } else {
                        browseHint
                    }
                }
                Divider()
            }
            favoritesSection
            cachedSection
            Spacer(minLength: 0)
        }
        .padding(12)
        .navigationTitle("Atmosplorer")
        .alert(
            "Couldn't explore",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "Offline cache",
            isPresented: Binding(
                get: { cacheModel.errorMessage != nil },
                set: { if !$0 { cacheModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cacheModel.errorMessage ?? "")
        }
        .alert(
            "Large repo",
            isPresented: Binding(
                get: { cacheModel.pendingLargeMirror != nil },
                set: { if !$0 { cacheModel.cancelLargeMirror() } }
            )
        ) {
            Button("Mirror anyway") { cacheModel.confirmLargeMirror() }
            Button("Cancel", role: .cancel) { cacheModel.cancelLargeMirror() }
        } message: {
            Text(largeMirrorMessage)
        }
    }

    private var largeMirrorMessage: String {
        guard let pending = cacheModel.pendingLargeMirror else { return "" }
        let name = pending.identity.handle ?? pending.identity.did
        return "\(name)'s archive is about \(CacheModel.formatBytes(pending.size)). "
            + "Mirroring downloads the full repo once for offline browsing — continue?"
    }

    // MARK: - entry

    private var entryField: some View {
        HStack(spacing: 6) {
            TextField("handle or DID", text: $handleInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit { explore(handleInput) }
                .disabled(model.isLoading)
            Button {
                explore(handleInput)
            } label: {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(handleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// Exploring a new identity supersedes whatever cached repo is currently
    /// shown in the detail column.
    private func explore(_ input: String) {
        cacheModel.selectedDid = nil
        Task { await model.explore(input) }
    }

    // MARK: - identity + mirror

    private func identitySummary(_ identity: ZatIdentity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(identity.handle ?? identity.did)
                .font(.headline)
                .lineLimit(1)
            if let pds = identity.pds {
                Text(pds)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            mirrorButton(identity)
        }
    }

    /// The primary action: pull the whole CAR once, persist it, and open the
    /// fully-offline browse (the detail column switches to CachedRepoView as
    /// soon as the mirror completes). Shows real stage progress and a cancel
    /// affordance while downloading/decoding.
    @ViewBuilder
    private func mirrorButton(_ identity: ZatIdentity) -> some View {
        if cacheModel.cached(identity.did) {
            Button {
                cacheModel.selectedDid = identity.did
            } label: {
                Label("Mirrored — browse offline", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Button {
                    cacheModel.mirror(identity: identity)
                } label: {
                    HStack(spacing: 6) {
                        if cacheModel.isDownloading {
                            ProgressView().controlSize(.small)
                        }
                        Text(mirrorButtonTitle)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(cacheModel.isDownloading)

                if cacheModel.isDownloading {
                    Button {
                        cacheModel.cancelMirror()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel mirroring")
                }
            }
        }
    }

    private var mirrorButtonTitle: String {
        switch cacheModel.mirrorPhase {
        case .probing: return "Checking size…"
        case .downloading: return "Downloading CAR…"
        case .decoding:
            if let bytes = cacheModel.downloadedBytes {
                return "Decoding \(CacheModel.formatBytes(bytes))…"
            }
            return "Decoding…"
        case .idle: return "Mirror repo"
        }
    }

    // MARK: - demoted live preview

    private var livePreviewToggle: some View {
        Toggle(isOn: $showLivePreview) {
            Text("Browse live (preview)")
                .font(.callout)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var browseHint: some View {
        Text("Mirror the repo to browse its collections fully offline.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var collectionList: some View {
        if let collections = model.description?.collections {
            List(collections, id: \.self, selection: $model.selectedCollection) { collection in
                VStack(alignment: .leading, spacing: 2) {
                    CollectionLabel(nsid: collection)
                    Text(collection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .listStyle(.sidebar)
        } else if model.isLoading {
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolving identity…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.small)
            }
            .padding(.top, 8)
        } else if case .failed = model.phase {
            EmptyView()
        } else {
            Text("Enter a handle or DID to see its collections.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    // MARK: - offline library

    @ViewBuilder
    private var cachedSection: some View {
        if !cacheModel.repos.isEmpty {
            Text("Cached (offline)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            List(cacheModel.repos, selection: cachedSelection) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.displayName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(cachedRepoSubtitle(repo))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Remove from cache", role: .destructive) {
                        cacheModel.remove(repo)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 0, maxHeight: 200)
        }
    }

    // MARK: - favorites

    /// The bookmarked-records section: newest first, each row opening the
    /// same record detail view the browser uses — fully offline, since the
    /// decoded value is stored with the favorite.
    @ViewBuilder
    private var favoritesSection: some View {
        if !favoritesModel.favorites.isEmpty {
            Text("Favorites")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            List(favoritesModel.favorites, selection: favoritesSelection) { favorite in
                VStack(alignment: .leading, spacing: 2) {
                    RecordRow(uri: favorite.uri, cid: favorite.cid, value: favorite.value)
                    Text(favorite.repoName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contextMenu {
                    Button("Remove from favorites", role: .destructive) {
                        favoritesModel.remove(uri: favorite.uri)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minHeight: 0, maxHeight: 160)
        }
    }

    /// Selecting a favorite clears the cached-repo selection so the detail
    /// column shows the record, not a repo.
    private var favoritesSelection: Binding<String?> {
        Binding(
            get: { favoritesModel.selectedURI },
            set: { newValue in
                favoritesModel.selectedURI = newValue
                if newValue != nil { cacheModel.selectedDid = nil }
            })
    }

    /// Selecting a cached repo clears the favorite selection so the detail
    /// column shows the repo browser, not a saved record.
    private var cachedSelection: Binding<String?> {
        Binding(
            get: { cacheModel.selectedDid },
            set: { newValue in
                cacheModel.selectedDid = newValue
                if newValue != nil { favoritesModel.selectedURI = nil }
            })
    }

    private func cachedRepoSubtitle(_ repo: CachedRepo) -> String {
        let size = repo.carByteCount.map { CacheModel.formatBytes($0) } ?? "size unknown"
        var text = "\(repo.recordCount) records · \(size)"
        if repo.mirrorCount > 1 {
            text += " · mirrored \(repo.mirrorCount)×"
            if let growth = repo.sizeGrowthBytes, growth >= 0 {
                text += " · +" + CacheModel.formatBytes(growth)
            }
        }
        return "\(text) · " + repo.cachedAt.formatted(date: .abbreviated, time: .omitted)
    }
}
