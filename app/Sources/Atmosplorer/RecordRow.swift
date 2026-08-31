import Zat
import SwiftUI
import ZatAppCore

/// One row in the records list: a collection-tinted type icon + rkey, then a
/// one-line preview of the body computed from the record's `$type` (posts show
/// their text, likes show what was liked, follows show who was followed, etc.),
/// and a trailing star for bookmarking straight from the list.
@MainActor
struct RecordRow: View {
    @EnvironmentObject private var favorites: FavoritesModel
    let uri: String
    let cid: String?
    let value: ZatJSONValue
    let content: RecordContent

    init(record: ZatRecord<ZatJSONValue>) {
        self.uri = record.uri
        self.cid = record.cid
        self.value = record.value
        self.content = RecordContent(value: record.value)
    }

    init(uri: String, cid: String? = nil, value: ZatJSONValue) {
        self.uri = uri
        self.cid = cid
        self.value = value
        self.content = RecordContent(value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CollectionLabel(nsid: nsid, iconOnly: true)
                Text(rkey)
                    .font(.system(.body, design: .monospaced))
                Spacer(minLength: 8)
                Button {
                    favorites.toggle(RecordSelection(uri: uri, cid: cid, value: value))
                } label: {
                    Image(systemName: favorites.contains(uri) ? "star.fill" : "star")
                        .foregroundStyle(favorites.contains(uri) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(favorites.contains(uri) ? "Remove from favorites" : "Add to favorites")
            }
            RecordContentView(content: content, presentation: .row)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var nsid: String {
        uri.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""
    }

    private var rkey: String {
        uri.split(separator: "/").last.map(String.init) ?? uri
    }
}