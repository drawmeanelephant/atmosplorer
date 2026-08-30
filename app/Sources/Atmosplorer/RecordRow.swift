import Zat
import SwiftUI
import ZatAppCore

/// One row in the records list: a collection-tinted type icon + rkey, then a
/// one-line preview of the body computed from the record's `$type` (posts show
/// their text, likes show what was liked, follows show who was followed, etc.).
struct RecordRow: View {
    let uri: String
    let content: RecordContent

    init(record: ZatRecord<ZatJSONValue>) {
        self.uri = record.uri
        self.content = RecordContent(value: record.value)
    }

    init(uri: String, value: ZatJSONValue) {
        self.uri = uri
        self.content = RecordContent(value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                CollectionLabel(nsid: nsid, iconOnly: true)
                Text(rkey)
                    .font(.system(.body, design: .monospaced))
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