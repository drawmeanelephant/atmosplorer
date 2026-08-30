import SwiftUI
import ZatAppCore

/// A collection's display metadata: an SF Symbol tinted by the collection's
/// color bucket, plus (unless icon-only) the human label. Used in the
/// sidebar, the offline collections list, and every record row.
@MainActor
struct CollectionLabel: View {
    let nsid: String
    var iconOnly = false

    private var info: CollectionInfo {
        CollectionInfo.info(for: nsid)
    }

    var body: some View {
        Label {
            if !iconOnly {
                Text(info.label)
            }
        } icon: {
            Image(systemName: info.symbol)
                .foregroundStyle(tint)
                .symbolVariant(info.tint.isFilled ? .fill : .none)
        }
    }

    private var tint: Color {
        switch info.tint {
        case .blue: return .blue
        case .green: return .green
        case .purple: return .purple
        case .orange: return .orange
        case .red: return .red
        case .teal: return .teal
        case .gray: return .secondary
        }
    }
}