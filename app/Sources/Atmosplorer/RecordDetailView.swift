import Zat
import SwiftUI
import ZatAppCore

/// A single record: the type-aware content presentation on top (same
/// extraction as the list rows, in full detail form), then the record's
/// at:// URI, CID, and full decoded body as a collapsible JSON tree.
@MainActor
struct RecordDetailView: View {
    let selection: RecordSelection

    var body: some View {
        List {
            Section("Content") {
                RecordContentView(
                    content: RecordContent(value: selection.value),
                    presentation: .detail)
            }
            Section("Record") {
                LabeledContent("URI", value: selection.uri)
                if let cid = selection.cid {
                    LabeledContent("CID", value: cid)
                }
            }
            Section("Value") {
                JSONTreeView(value: selection.value)
            }
        }
        .navigationTitle(rkey)
        .textSelection(.enabled)
    }

    private var rkey: String {
        selection.uri.split(separator: "/").last.map(String.init) ?? selection.uri
    }
}

/// Recursive collapsible renderer for `ZatJSONValue`. Objects and arrays are
/// DisclosureGroups; leaves are labeled rows.
@MainActor
struct JSONTreeView: View {
    let value: ZatJSONValue

    var body: some View {
        node(value)
    }

    @ViewBuilder
    private func node(_ value: ZatJSONValue) -> some View {
        switch value {
        case .object(let object):
            if object.isEmpty {
                emptyHint("empty object")
            } else {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    row(label: key, child: object[key] ?? .null)
                }
            }
        case .array(let items):
            if items.isEmpty {
                emptyHint("empty array")
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, child in
                    row(label: "[\(index)]", child: child)
                }
            }
        default:
            Text(Self.leafText(value))
        }
    }

    @ViewBuilder
    private func emptyHint(_ title: String) -> some View {
        LabeledContent(title, value: "∅")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(label: String, child: ZatJSONValue) -> some View {
        if Self.isLeaf(child) {
            LabeledContent(label, value: Self.leafText(child))
        } else {
            // AnyView breaks the recursive opaque-type cycle (node → row →
            // node would otherwise infer a self-referential `some View`).
            DisclosureGroup(label) {
                AnyView(node(child))
                    .padding(.leading, 8)
            }
        }
    }

    /// Walks the exact nodes the view renders and returns every leaf text.
    /// Test hook: proves the tree force-builds without crashing for arbitrary
    /// record bodies. Pure data traversal, so it is `nonisolated` and callable
    /// from any executor.
    nonisolated static func forceBuildAllLeafTexts(_ value: ZatJSONValue) -> [String] {
        var out: [String] = []
        walk(value, &out)
        return out
    }

    private nonisolated static func walk(_ value: ZatJSONValue, _ out: inout [String]) {
        switch value {
        case .object(let object):
            if object.isEmpty { out.append("∅") }
            for key in object.keys.sorted() { walk(object[key] ?? .null, &out) }
        case .array(let items):
            if items.isEmpty { out.append("∅") }
            for item in items { walk(item, &out) }
        default:
            out.append(leafText(value))
        }
    }

    private nonisolated static func isLeaf(_ value: ZatJSONValue) -> Bool {
        switch value {
        case .object, .array: return false
        default: return true
        }
    }

    private nonisolated static func leafText(_ value: ZatJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .object, .array: return "…"
        }
    }
}
