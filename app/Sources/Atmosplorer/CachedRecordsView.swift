import SwiftUI
import ZatAppCore

/// One collection's records from a decoded cached repo. Values are shaped as
/// `ZatRecord` by `OfflineRepo`, so this reuses the live walk's rows and
/// detail view exactly.
@MainActor
struct CachedRecordsView: View {
    let did: String
    let repo: OfflineRepo
    let collection: String

    var body: some View {
        let records = repo.records(in: collection)
        List {
            ForEach(records, id: \.uri) { record in
                NavigationLink(value: RecordSelection(
                    uri: record.uri, cid: record.cid, value: record.value)) {
                    RecordRow(record: record)
                }
            }
        }
        .navigationTitle(CollectionInfo.info(for: collection).label)
        .navigationSubtitle("\(collection) · \(records.count) records · offline")
        .navigationDestination(for: RecordSelection.self) { selection in
            RecordDetailView(selection: selection)
        }
    }
}
