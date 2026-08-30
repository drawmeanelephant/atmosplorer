import SwiftUI
import Zat
import ZatAppCore

/// Drives offline search over one cached repo. Loads the search index (the
/// validated on-disk `jsonl`, or — when missing/stale — extracts entries from
/// the already-decoded repo) off the main thread, then turns a debounced
/// query into ranked `LocalSearch.Result`s, each of which opens the same
/// `RecordDetailView` the offline browser uses.
///
/// All the heavy lifting — loading/decoding the index and tokenizing + scoring
/// hundreds of thousands of entries — is pushed off the main thread (a
/// detached worker against the pure, value-type `LocalSearch`), so neither
/// first search of a mirror without an on-disk index nor keystrokes block the
/// UI. Only the small result heads come back to the main actor.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [LocalSearch.Result] = []
    @Published private(set) var isSearching = false
    /// True while the index is loading/decoding on a background thread, before
    /// the field becomes matchable.
    @Published private(set) var isPreparing = false

    private let did: String
    private let repo: OfflineRepo
    private let cache: RepoCache

    /// The loaded search surface (nil until the background prepare finishes).
    private var prepared: Prepared? {
        didSet {
            if prepared != nil {
                for reader in readers { reader.resume() }
                readers.removeAll()
            }
            isPreparing = false
        }
    }
    /// Queries suspended waiting for indexing to finish.
    private var readers: [CheckedContinuation<Void, Never>] = []

    init(did: String, repo: OfflineRepo, cache: RepoCache) {
        self.did = did
        self.repo = repo
        self.cache = cache
        // Kick the index load off the calling (main) thread right away; the
        // view shows the collections list until the query field activates, so
        // first search is already ready in the common case.
        isPreparing = true
        Task { await prepare() }
    }

    /// True when the user has typed a non-empty query (shows the results
    /// surface in place of the collections list).
    var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Run the current query. Debounce happens in the view layer via
    /// `.task(id: query)` — each keystroke cancels this task, and the small
    /// sleep here absorbs the bursts so only the settled query scores.
    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        do { try await Task.sleep(for: .milliseconds(150)) }
        catch { return }  // cancelled by a newer keystroke

        // Hold the query until the on-disk (or fallback) index is ready.
        await awaitPrepared()
        guard !Task.isCancelled, let index = prepared?.index else {
            isSearching = false
            return
        }

        // Score against the pre-tokenized index (built once in `prepare`),
        // so each keystroke's work is scoring only.
        let heads = await Task.detached(priority: .userInitiated) {
            LocalSearch.results(for: trimmed, prepared: index)
        }.value
        guard !Task.isCancelled else { return }
        results = heads
        isSearching = false
    }

    /// Turn a search hit into a navigation selection, reusing the identical
    /// at:// URI synthesis and `RecordDetailView` the offline browser uses.
    func selection(for result: LocalSearch.Result) -> RecordSelection {
        let path = result.entry.path
        return RecordSelection(
            uri: "at://\(did)/\(path)",
            cid: result.entry.cid,
            value: prepared?.valuesByPath[path] ?? .null)
    }

    // MARK: - off-main preparation

    /// The search surface: the pre-tokenized index (reused across keystrokes)
    /// plus the record values needed to open a hit. Built once, off the main
    /// thread.
    private struct Prepared {
        let index: LocalSearch.PreparedIndex
        /// Maps a record's MST path to its decoded value, so a search hit can
        /// push a real `RecordSelection` (the search index omits values).
        let valuesByPath: [String: ZatJSONValue]
    }

    private func prepare() async {
        let did = self.did
        let repo = self.repo
        let cache = self.cache
        let result = await Task.detached(priority: .userInitiated) {
            Self.build(did: did, repo: repo, cache: cache)
        }.value
        guard !Task.isCancelled else { return }
        prepared = result
    }

    /// Pure, background-eligible construction: prefer the validated on-disk
    /// index; otherwise extract entries from the already-decoded repo and
    /// persist them lazily so the next open loads from disk instead of
    /// re-extracting. Builds the path→value map in the same pass.
    /// `nonisolated` so it can run on a detached worker without touching the
    /// main actor.
    private nonisolated static func build(did: String, repo: OfflineRepo, cache: RepoCache) -> Prepared {
        let stored = SearchIndex.load(did: did, recordCount: repo.recordCount, in: cache.directory)
        let entries: [SearchIndexEntry]
        if let stored {
            entries = stored.entries
        } else {
            // No valid on-disk index: extract from the decoded repo, then
            // persist it (best-effort, same spirit as the mirror-time write)
            // so a future open pays the extraction once instead of every
            // time. A failed write only costs another fallback build.
            entries = SearchIndex.entries(from: repo.records)
            try? SearchIndex.store(did: did, entries: entries, in: cache.directory)
        }
        // Tokenize every field + parse every date once (the expensive part),
        // so per-keystroke scoring is cheap at 275k-record scale.
        var byPath: [String: ZatJSONValue] = [:]
        for record in repo.records { byPath[record.path] = record.value }
        return Prepared(index: LocalSearch.prepare(entries), valuesByPath: byPath)
    }

    private func awaitPrepared() async {
        if prepared != nil { return }
        await withCheckedContinuation { continuation in
            readers.append(continuation)
        }
    }
}

/// Search results surface: one `RecordRow` per hit (the same row the
/// collections use), each navigating to `RecordDetailView`.
struct SearchResultsView: View {
    @ObservedObject var model: SearchModel

    var body: some View {
        List {
            if model.isPreparing && model.results.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Indexing records for search…")
                }
                .foregroundStyle(.secondary)
            } else if model.isSearching && model.results.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                }
                .foregroundStyle(.secondary)
            } else if model.results.isEmpty {
                Text("No matching records.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.results, id: \.entry.path) { result in
                    let selection = model.selection(for: result)
                    NavigationLink(value: selection) {
                        RecordRow(uri: selection.uri, value: selection.value)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}