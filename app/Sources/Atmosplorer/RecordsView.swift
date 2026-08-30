import Zat
import SwiftUI
import ZatAppCore

/// Hashable selection payload so `navigationDestination` can carry a record
/// (ZatRecord itself isn't Hashable).
struct RecordSelection: Hashable {
    let uri: String
    let cid: String?
    let value: ZatJSONValue
}

/// The detail column: one collection's records, paged, with navigation into
/// each record's decoded JSON.
@MainActor
struct RecordsView: View {
    @StateObject private var model: RecordsModel
    private let collection: String
    private let identity: ZatIdentity?

    init(session: AppSession, repo: String, collection: String, identity: ZatIdentity?) {
        _model = StateObject(wrappedValue: RecordsModel(
            session: session, repo: repo, collection: collection))
        self.collection = collection
        self.identity = identity
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.records, id: \.uri) { record in
                    NavigationLink(value: RecordSelection(
                        uri: record.uri, cid: record.cid, value: record.value)) {
                        RecordRow(record: record)
                    }
                }
                if !model.isExhausted {
                    loadMoreRow
                }
            }
            .navigationTitle(CollectionInfo.info(for: collection).label)
            .navigationSubtitle(ownerName.isEmpty ? collection : "\(collection) · \(ownerName)")
            .navigationDestination(for: RecordSelection.self) { selection in
                RecordDetailView(selection: selection)
            }
            .overlay { stateOverlay }
            .task { await model.loadFirstPage() }
        }
    }

    private var ownerName: String {
        identity?.handle ?? ""
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if model.records.isEmpty && (!model.hasLoadedFirstPage || model.isLoading) {
            ProgressView(model.hasLoadedFirstPage ? "Loading records…" : "In the queue…")
        } else if model.records.isEmpty, let message = model.errorMessage {
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
        } else if model.records.isEmpty {
            Text("No records in this collection.")
                .foregroundStyle(.secondary)
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if model.reachedPreviewCap {
                // The live browse is an opt-in preview; the full listing lives
                // in the mirrored copy.
                Label("Live preview capped — mirror the repo for the full listing",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Load more…")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
