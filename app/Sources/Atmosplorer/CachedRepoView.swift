import SwiftUI
import ZatAppCore

/// The detail column for a cached repo: its collections (derived from the
/// decoded CAR — no network), drilling into each collection's records.
struct CachedRepoView: View {
    @StateObject private var model: CachedRepoBrowserModel

    /// Created once the repo finishes decoding; needs the decoded `OfflineRepo`
    /// to source the search entries and record values.
    @State private var searchModel: SearchModel?

    init(did: String, displayName: String, cacheModel: CacheModel, offlineSession: AppSession) {
        _model = StateObject(wrappedValue: CachedRepoBrowserModel(
            did: did, displayName: displayName,
            cache: cacheModel.cache, session: offlineSession))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Decoding cached repo…")
                case .failed(let message):
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                case .loaded:
                    if let repo = model.offline {
                        if let search = searchModel, search.isActive {
                            SearchResultsView(model: search)
                        } else {
                            collectionsList(repo)
                        }
                    }
                }
            }
            // Injected so nested rows/detail can resolve like/follow/block
            // subjects to people (and starter-pack feeds to entities) from
            // one shared resolver; offline them to the raw identifier.
            .environment(\.identityResolver, model.resolver)
            .navigationTitle(model.displayName)
            .navigationSubtitle("\(model.recordCount) records · offline")
            // Open a search hit through the exact same detail view the
            // collection rows use.
            .navigationDestination(for: RecordSelection.self) { selection in
                RecordDetailView(selection: selection)
            }
            .searchable(
                text: searchQuery,
                placement: .toolbar,
                prompt: "Search \(model.recordCount) records")
            .task { await model.load() }
            .task(id: model.offline) {
                if let repo = model.offline, searchModel == nil {
                    searchModel = SearchModel(did: model.did, repo: repo, cache: model.cache)
                }
            }
            .task(id: searchModel?.query) { await searchModel?.search() }
        }
    }

    /// Bind to the search model's query even before it exists (while decoding),
    /// so `.searchable` has a stable target from first render.
    private var searchQuery: Binding<String> {
        Binding(
            get: { searchModel?.query ?? "" },
            set: { newValue in searchModel?.query = newValue })
    }

    private func collectionsList(_ repo: OfflineRepo) -> some View {
        List(repo.collections, id: \.self) { collection in
            NavigationLink(value: collection) {
                VStack(alignment: .leading, spacing: 2) {
                    CollectionLabel(nsid: collection)
                    Text(collection)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(repo.records(in: collection).count) records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(for: String.self) { collection in
            CachedRecordsView(did: model.did, repo: repo, collection: collection)
        }
    }
}
