import SwiftUI
import ZatAppCore

/// The window: sidebar (handle → identity → collections, plus the offline
/// cache library) and a detail column that either walks the live records or
/// browses a cached repo entirely offline.
@MainActor
struct RootView: View {
    @StateObject private var model = RootModel()
    @StateObject private var cacheModel = CacheModel()
    @State private var handleInput = ""
    /// Live browsing is an opt-in preview, off by default: the materialized
    /// copy (Mirror repo) is the primary browse.
    @State private var showLivePreview = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, cacheModel: cacheModel,
                        handleInput: $handleInput, showLivePreview: $showLivePreview)
        } detail: {
            detailColumn
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let did = cacheModel.selectedDid,
           let offlineSession = cacheModel.offlineSession {
            // Offline: a cached repo selected in the sidebar. Decoding runs
            // on the offline session's queue and touches no network.
            let displayName = cacheModel.repos.first { $0.did == did }?.displayName ?? did
            CachedRepoView(did: did, displayName: displayName,
                           cacheModel: cacheModel, offlineSession: offlineSession)
                .id(did)
        } else if showLivePreview,
                  let session = model.session,
                  let description = model.description,
                  let collection = model.selectedCollection {
            // Opt-in live preview, bounded by RecordsModel.maxPreviewPages.
            RecordsView(
                session: session,
                repo: description.did,
                collection: collection,
                identity: model.identity
            )
            .id(collection) // fresh paging state when switching collections
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Explore an AT Protocol repo")
                .font(.title3)
            Text("Enter a handle or DID in the sidebar to see its identity.\nMirror it to browse the full repo offline — or enable the live preview.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
