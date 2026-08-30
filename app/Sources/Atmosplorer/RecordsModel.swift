import Zat
import Foundation
import ZatAppCore

/// One collection's records, paged via the listRecords cursor. The live
/// browse is an opt-in *preview*: it pages until the server stops returning a
/// cursor or until `maxPreviewPages` is reached, whichever comes first — the
/// full listing lives in the mirrored copy.
@MainActor
final class RecordsModel: ObservableObject {
    @Published var records: [ZatRecord<ZatJSONValue>] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// True once we've actually attempted the first page, so the view can
    /// distinguish "not loaded yet" from "loaded and genuinely empty".
    @Published private(set) var hasLoadedFirstPage = false
    /// True once the live pager has hit its page cap: the live browse is an
    /// opt-in *preview* — the full listing lives in the mirrored copy.
    @Published private(set) var reachedPreviewCap = false

    /// Live browsing is deliberately bounded: after this many pages, stop and
    /// point at the mirrored copy instead of paging through the whole repo.
    static let maxPreviewPages = 10

    private let session: AppSession
    private let repo: String
    private let collection: String
    private var cursor: String?
    private var pagesLoaded = 0
    /// Bumped on every `loadFirstPage` so an in-flight (or abandoned) page
    /// from a previous load can't overwrite a fresher one. The view is
    /// recreated per collection via `.id(collection)`, so this mainly guards
    /// against a stale, slow load racing a new first page after a switch.
    private var generation = 0

    init(session: AppSession, repo: String, collection: String) {
        self.session = session
        self.repo = repo
        self.collection = collection
    }

    /// True once a fetch returned no cursor (the listing is exhausted).
    var isExhausted: Bool {
        cursor == nil && !records.isEmpty
    }

    func loadFirstPage() async {
        generation += 1
        let gen = generation
        records = []
        cursor = nil
        errorMessage = nil
        hasLoadedFirstPage = true
        pagesLoaded = 0
        reachedPreviewCap = false
        await loadMore(generation: gen)
    }

    func loadMore() async {
        await loadMore(generation: generation)
    }

    private func loadMore(generation gen: Int) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Not worth issuing the request if this load has already been
        // superseded by a newer first page or the view is being torn down.
        guard gen == generation, !Task.isCancelled else { return }
        do {
            let page = try await session.listRecords(
                repo: repo, collection: collection, limit: 25, cursor: cursor)
            // The response arrived, but only apply it if nothing fresher has
            // started since — a stale page must never overwrite a newer load.
            guard gen == generation, !Task.isCancelled else { return }
            records.append(contentsOf: page.records)
            cursor = page.cursor
            pagesLoaded += 1
            if pagesLoaded >= Self.maxPreviewPages {
                reachedPreviewCap = true
            }
        } catch let error as AppError {
            guard gen == generation, !Task.isCancelled else { return }
            errorMessage = error.userMessage
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            errorMessage = "Something unexpected went wrong."
        }
    }
}
